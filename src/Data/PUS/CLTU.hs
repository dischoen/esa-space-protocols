{-|
Module      : Data.PUS.CLTU
Description : Provides functions for CLTU (Command Link Transfer Unit) handling
Copyright   : (c) Michael Oswald, 2019
License     : BSD-3
Maintainer  : michael.oswald@onikudaki.net
Stability   : experimental
Portability : POSIX

This module is used for encoding and decoding to and from CLTU's. A TC Randomizer can be used, which is 
basically an array of values which are xor'ed with the CLTU block data so that the distribution of 
0's and 1's is more even (better for transmission to the satellite).
-}
{-# LANGUAGE BangPatterns
    , OverloadedStrings #-}
module Data.PUS.CLTU
    ( CLTU
    , cltuNew
    , cltuPayLoad
    , encode
    , encodeRandomized
    , cltuParser
    , cltuRandomizedParser
    , cltuDecodeC
    , cltuDecodeRandomizedC
    , cltuEncodeC
    , cltuEncodeRandomizedC
    )
where


import           Control.Monad                  ( void )

import qualified Data.ByteString.Lazy          as BL
import           Data.ByteString.Builder
import           Data.ByteString                ( ByteString )
import qualified Data.ByteString               as BS

import           Data.Word
import           Data.Int
import           Data.Bits
import           Data.Text                      ( Text )
import           Data.List                      ( mapAccumL )
import qualified Data.Text                     as T

import           Data.PUS.Config
import           Data.PUS.CLTUTable
import           Data.PUS.Randomizer

import qualified TextShow                      as TS
import           TextShow.Data.Integral

import           General.Chunks
import           General.Hexdump


import           Data.Attoparsec.ByteString     ( Parser )
import qualified Data.Attoparsec.ByteString    as A

import           Data.Conduit
import           Data.Conduit.Attoparsec


-- The CLTU itself
data CLTU = CLTU {
    -- | returns the actual binary payload data (mostly a TC transfer frame)
    cltuPayLoad :: BS.ByteString
} deriving Eq


instance Show CLTU where
    show (CLTU x) = "CLTU:\n" <> T.unpack (hexdumpBS x)



{-# INLINABLE cltuNew #-}
-- | create a CLTU from a payload, which will mostly be a TC transfer frame
cltuNew :: ByteString -> CLTU
cltuNew = CLTU

{-# INLINABLE cltuHeader #-}
-- | The CLTU header 0xeb90
cltuHeader :: ByteString
cltuHeader = BS.pack [0xeb, 0x90]

-- | The CLTU trailer 
{-# INLINABLE cltuTrailer #-}
cltuTrailer :: Int -> ByteString
cltuTrailer n = BS.replicate (fromIntegral n) 0x55



cltuHeaderParser :: Parser ()
cltuHeaderParser = do
    void $ A.word8 0xEB
    void $ A.word8 0x90

-- | Attoparsec parser for a CLTU. 
cltuParser :: Config -> Parser CLTU
cltuParser cfg = do
    let cbSize  = cltuBlockSizeAsWord8 (cfgCltuBlockSize cfg)
        dataLen = cbSize - 1

    cltuHeaderParser

    codeBlocks <- A.many1 (codeBlockParser (fromIntegral dataLen))

    let proc _ (Left err) = Left err
        proc (bs, parity) (Right cb) =
            case checkCodeBlockParity cbSize bs parity of
                Left  err       -> Left err
                Right dataBlock -> Right (dataBlock : cb)

        checkedCBs = foldr proc (Right mempty) codeBlocks

    case checkedCBs of
        Left  err   -> fail (T.unpack err)
        Right parts -> do
            let bs =
                    ( BL.toStrict
                    . toLazyByteString
                    . mconcat
                    . map byteString
                    $ parts
                    )
                (res, _) = BS.spanEnd (== 0x55) bs
            pure (CLTU res)


codeBlockParser :: Int -> Parser (BS.ByteString, Word8)
codeBlockParser dataLen = (,) <$> A.take dataLen <*> A.anyWord8


-- | Attoparsec parser for a randomized CLTU. 
cltuRandomizedParser :: Config -> Parser CLTU
cltuRandomizedParser cfg = do
    let cbSize     = cltuBlockSizeAsWord8 (cfgCltuBlockSize cfg)
        dataLen    = cbSize - 1
        randomizer = initialize (cfgRandomizerStartValue cfg)

    cltuHeaderParser

    codeBlocks <- A.many1 (codeBlockParser (fromIntegral dataLen))

    let proc _ [] acc = Right (reverse acc)
        proc r ((x, parity) : xs) acc =
            case checkCodeBlockRandomizedParity r cbSize x parity of
                Left  err           -> Left err
                Right (newR, block) -> proc newR xs (block : acc)

    case proc randomizer codeBlocks [] of
        Left  err   -> fail (T.unpack err)
        Right parts -> do
            let bs =
                    ( BL.toStrict
                    . toLazyByteString
                    . mconcat
                    . map byteString
                    $ parts
                    )
                (res, _) = BS.spanEnd (== 0x55) bs
            pure (CLTU res)


-- | A conduit for decoding CLTUs from a ByteString stream
cltuDecodeC
    :: Monad m
    => Config
    -> ConduitT
           BS.ByteString
           (Either ParseError (PositionRange, CLTU))
           m
           ()
cltuDecodeC cfg = conduitParserEither (cltuParser cfg)

-- | A conduit for decoding randomized CLTUs from a ByteString stream
cltuDecodeRandomizedC
    :: Monad m
    => Config
    -> ConduitT
           BS.ByteString
           (Either ParseError (PositionRange, CLTU))
           m
           ()
cltuDecodeRandomizedC cfg = conduitParserEither (cltuParser cfg)


-- | A conduit for encoding a CLTU in a ByteString for transmission
cltuEncodeC :: Monad m => Config -> ConduitT CLTU BS.ByteString m ()
cltuEncodeC cfg = awaitForever $ \cltu -> pure (encode cfg cltu)

-- | A conduit for encoding a CLTU in a ByteString for transmission
cltuEncodeRandomizedC :: Monad m => Config -> ConduitT CLTU BS.ByteString m ()
cltuEncodeRandomizedC cfg =
    awaitForever $ \cltu -> pure (encodeRandomized cfg cltu)


{-# INLINABLE encode #-}
-- | Encodes a CLTU into a ByteString suitable for sending via a transport protocol
-- Takes a config as some values of the CLTU ecoding can be specified per mission
-- (e.g. block length of the encoding)
encode :: Config -> CLTU -> ByteString
encode cfg cltu = encodeGeneric cfg cltu encodeCodeBlocks


{-# INLINABLE encodeRandomized #-}
-- | Encodes a CLTU into a ByteString suitable for sending via a transport protocol,
-- but randomizes the data before
-- Takes a config as some values of the CLTU ecoding can be specified per mission
-- (e.g. block length of the encoding)
encodeRandomized :: Config -> CLTU -> ByteString
encodeRandomized cfg cltu = encodeGeneric cfg cltu encodeCodeBlocksRandomized

{-# INLINABLE encodeGeneric #-}
encodeGeneric
    :: Config -> CLTU -> (Config -> ByteString -> Builder) -> ByteString
encodeGeneric cfg (CLTU pl) encoder = BL.toStrict
    $ toLazyByteString (mconcat [byteString cltuHeader, encodedFrame, trailer])
  where
    encodedFrame = encoder cfg pl
    trailer      = encodeCodeBlock
        (cltuTrailer
            (fromIntegral (cltuBlockSizeAsWord8 (cfgCltuBlockSize cfg) - 1))
        )




{-# INLINABLE encodeCodeBlocks #-}
-- | Takes a ByteString as payload, splits it into CLTU code blocks according to 
-- the configuration, calculates the parity for the code blocks by possibly 
-- padding the last code block with the trailer and returns a builder
-- with the result
encodeCodeBlocks :: Config -> ByteString -> Builder
encodeCodeBlocks cfg pl =
    let cbSize = fromIntegral $ cltuBlockSizeAsWord8 (cfgCltuBlockSize cfg) - 1
        blocks = chunkedByBS cbSize pl
        pad bs =
                let len = fromIntegral (BS.length bs)
                in  if len < cbSize
                        then BS.append bs (cltuTrailer (cbSize - len))
                        else bs
    in  mconcat $ map (encodeCodeBlock . pad) blocks


{-# INLINABLE encodeCodeBlocksRandomized #-}
-- | Takes a ByteString as payload, splits it into CLTU code blocks according to 
-- the configuration, applies randomization, calculates the parity for the code blocks by possibly 
-- padding the last code block with the trailer and returns a builder
-- with the result
encodeCodeBlocksRandomized :: Config -> ByteString -> Builder
encodeCodeBlocksRandomized cfg pl =
    let
        cbSize = fromIntegral $ cltuBlockSizeAsWord8 (cfgCltuBlockSize cfg) - 1
        blocks = map pad $ chunkedByBS cbSize pl
        randomizer = initialize (cfgRandomizerStartValue cfg)
        pad bs =
            let len = fromIntegral (BS.length bs)
            in  if len < cbSize
                    then BS.append bs (cltuTrailer (cbSize - len))
                    else bs

        (_, builderBlocks) =
            mapAccumL encodeCodeBlockRandomized randomizer blocks
    in
        mconcat builderBlocks


{-# INLINABLE encodeCodeBlock #-}
-- | encodes a single CLTU code block. This function assumes that the given ByteString
-- is already in the correct code block length - 1 (1 byte for parity will be added)
encodeCodeBlock :: ByteString -> Builder
encodeCodeBlock block = byteString block <> word8 (cltuParity block)


{-# INLINABLE encodeCodeBlockRandomized #-}
-- | encodes a single CLTU code block and applies randomization. This function assumes that the given ByteString
-- is already in the correct code block length - 1 (1 byte for parity will be added)
encodeCodeBlockRandomized :: Randomizer -> ByteString -> (Randomizer, Builder)
encodeCodeBlockRandomized r block =
    let (newR, rblock) = randomize r False block
    in  (newR, byteString rblock <> word8 (cltuParity rblock))



{-# INLINABLE cltuParity #-}
-- | calculates the parity of a single code block. The code block is assumed to
-- be of the specified code block length
cltuParity :: ByteString -> Word8
cltuParity !block =
    let proc :: Word8 -> Int32 -> Int32
        proc !octet !sreg = fromIntegral $ cltuTable (fromIntegral sreg) octet
        sreg1   = BS.foldr proc 0 block
        !result = fromIntegral $ ((sreg1 `xor` 0xFF) `shiftL` 1) .&. 0xFE
    in  result



{-# INLINABLE checkCodeBlockParity #-}
-- | Checks a code block. First, it checks the length against the @expectedLen,
-- then checks the @parity. Returns either an error message or the data block without
-- the parity byte
checkCodeBlockParity :: Word8 -> ByteString -> Word8 -> Either Text ByteString
checkCodeBlockParity expectedLen checkBlock parity =
    let
        len              = BS.length checkBlock + 1
        calculatedParity = cltuParity checkBlock
    in
        if fromIntegral expectedLen /= len
            then Left $ TS.toText
                (  TS.fromText
                      "CLTU block does not have the right length, expected: "
                <> TS.showb expectedLen
                <> TS.fromText " received: "
                <> TS.showb len
                )
            else if calculatedParity == parity
                then
                    Right
                        (if BS.all (== 0x55) checkBlock
                            then BS.empty
                            else checkBlock
                        )
                else if BS.all (== 0x55) checkBlock
                    then Right BS.empty
                    else Left $ TS.toText
                        (  TS.fromText
                              "Error: CLTU code block check failed, calculated: "
                        <> showbHex calculatedParity
                        <> TS.fromText " received: "
                        <> showbHex parity
                        )


{-# INLINABLE checkCodeBlockRandomizedParity #-}
-- | Checks a code block. First, it checks the length against the @expectedLen,
-- then checks the @parity. Returns either an error message or the d-randomized data block without
-- the parity byte. 
checkCodeBlockRandomizedParity
    :: Randomizer
    -> Word8
    -> ByteString
    -> Word8
    -> Either Text (Randomizer, ByteString)
checkCodeBlockRandomizedParity r expectedLen checkBlock parity =
    let
        len              = BS.length checkBlock + 1
        calculatedParity = cltuParity checkBlock
    in
        if fromIntegral expectedLen /= len
            then Left $ TS.toText
                (  TS.fromText
                      "CLTU block does not have the right length, expected: "
                <> TS.showb expectedLen
                <> TS.fromText " received: "
                <> TS.showb len
                )
            else if calculatedParity == parity
                then Right (randomize r False checkBlock)
                else if BS.all (== 0x55) checkBlock
                    then Right (r, BS.empty)
                    else Left $ TS.toText
                        (  TS.fromText
                              "Error: CLTU code block check failed, calculated: "
                        <> showbHex calculatedParity
                        <> TS.fromText " received: "
                        <> showbHex parity
                        )





