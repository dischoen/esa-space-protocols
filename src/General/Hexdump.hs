{-# LANGUAGE OverloadedStrings 
#-}
module General.Hexdump 
    (
        hexdump
        , hexdumpBS
    ) 
where
    
    
import Data.Char 
import Data.Word
import Data.Text (Text)
import Data.Text.Lazy.Builder
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import Data.List (intersperse)
import TextShow

import General.Chunks

import Formatting


chunkSize :: Int
chunkSize = 4

lineChunkSize :: Int
lineChunkSize = 4


-- | hex-dumps the lazy ByteString into a strict Text value
hexdump :: BL.ByteString -> Text
hexdump bs = toText result
    where
        blocks = chunkedBy chunkSize bs 
        groups = chunks lineChunkSize blocks
        addresses :: [Word32]
        addresses = [0, fromIntegral (chunkSize * lineChunkSize) .. ]

        result = mconcat $ zipWith groupToLine addresses groups

        byteToHex :: Word8 -> Builder
        byteToHex x = fromLazyText $ format (left 2 '0' %. hex) x

        byteToChar :: Word8 -> Builder
        byteToChar x = 
            let c = chr (fromIntegral x)
            in 
            if isPrint c 
                then singleton c
                else singleton '.'

        chunkToText = mconcat . map byteToHex . BL.unpack 
        chunkToPrintable = mconcat . map byteToChar . BL.unpack

        groupToLine :: Word32 -> [BL.ByteString] -> Builder
        groupToLine addr line = 
            let content = 
                    fromLazyText (format (left 8 '0' %. hex % ": ") addr)
                        <> mconcat (intersperse (singleton ' ') (map chunkToText line))
                        <> fromLazyText "   "
                        <> mconcat (map chunkToPrintable line)
                        <> singleton '\n'
            in
                content



-- | hex-dumps the lazy ByteString into a strict Text value
hexdumpBS :: BS.ByteString -> Text
hexdumpBS bs = toText result
    where
        blocks = chunkedByBS chunkSize bs 
        groups = chunks lineChunkSize blocks
        addresses :: [Word32]
        addresses = [0, fromIntegral (chunkSize * lineChunkSize) .. ]

        result = mconcat $ zipWith groupToLine addresses groups

        byteToHex :: Word8 -> Builder
        byteToHex x = fromLazyText $ format (left 2 '0' %. hex) x

        byteToChar :: Word8 -> Builder
        byteToChar x = 
            let c = chr (fromIntegral x)
            in 
            if isPrint c 
                then singleton c
                else singleton '.'

        chunkToText = mconcat . map byteToHex . BS.unpack 
        chunkToPrintable = mconcat . map byteToChar . BS.unpack

        groupToLine :: Word32 -> [BS.ByteString] -> Builder
        groupToLine addr line = 
            let content = 
                    fromLazyText (format (left 8 '0' %. hex % ": ") addr)
                        <> mconcat (intersperse (singleton ' ') (map chunkToText line))
                        <> fromLazyText "   "
                        <> mconcat (map chunkToPrintable line)
                        <> singleton '\n'
            in
                content