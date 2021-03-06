module Data.JPEG.DataUnit where

import Control.Applicative
import Control.DeepSeq
import Control.Monad.Identity
import Control.Monad.State
import Data.Attoparsec
import Data.Attoparsec.Binary
import Data.Bits
import Data.Compression.Huffman
import Data.Default
import Data.Word
import Debug.Trace (trace)
import qualified Data.Map as M
import qualified Data.List as L
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Int

import Data.JPEG.JPEGState
import Data.JPEG.Markers
import Data.JPEG.Util

-- F.2.2.1
extend :: (Bits a, Ord a) => a -> Int -> a
extend v t
  | v == 0 && t == 0 = 0
  | v < vt = v + (-1 `shiftL` t) + 1
  | otherwise = v
  where vt = 2 ^ (t - 1)

type BitState = (Word8, Word8, M.Map Word8 Int, Int)  -- cnt, b, (c -> pred), eobrun

-- F.2.2.5
nextBit :: StateT BitState Parser Word8
nextBit = do
  (cnt, b, pred, eobrun) <- get
  if cnt == 0
    then do
      b' <- lift anyWord8
      if b' == 0xFF
        then do
          b2 <- lift anyWord8
          if b2 == 0x00
            then out 8 b' pred eobrun
            else trace ("Unexpected marker: " ++ (show b2)) $ lift $ fail "Unexpected marker"
        else out 8 b' pred eobrun
    else out cnt b pred eobrun
  where out cnt b pred eobrun = do
          put (cnt - 1, b `shiftL` 1, pred, eobrun)
          return $ b `shiftR` 7

-- F.2.2.4
receive :: (Bits b, Num a) => a -> StateT BitState Parser b
receive s = helper s 0 0
  where helper s i v
         | i == s = return v
         | otherwise = do
           nb <- nextBit
           helper s (i + 1) ((v `shiftL` 1) + (fromIntegral nb))

-- F.2.2.3
decode :: HuffmanTree a -> StateT BitState Parser a
decode Empty = trace "Value not in huffman tree" $ lift $ fail "Value not in huffman tree"
decode (Leaf x) = return x
decode (Node l r) = do
  nb <- nextBit
  decode $ if nb == 1 then r else l

-- F.2.2.1
diff :: (Num a, Integral a) => Word8 -> HuffmanTree a -> StateT BitState Parser Int
diff c tree = do
  t <- decode tree
  d <- receive t
  (cnt, b, pred_m, eobrun) <- get
  let dc = (pred_m M.! c) + (extend d $ fromIntegral t)
  put (cnt, b, M.insert c dc pred_m, eobrun)
  return dc

type DataUnitFunc = Word8 -> HuffmanTree Word8 -> HuffmanTree Word8 -> Word8 -> Word8 -> Word8 -> Word8 -> StateT BitState Parser (U.Vector Int)
type UpdateDataUnitFunc = U.Vector Int -> DataUnitFunc

decodeSequentialDataUnit :: DataUnitFunc
decodeSequentialDataUnit c dctree actree 0 63 0 0 = do
  dc <- decodeDCDataUnit c dctree actree 0 63 0 0
  ac <- decodeACScans dc c dctree actree 1 63 0 0
  return ac

decodeDCDataUnit :: DataUnitFunc
decodeDCDataUnit c tree _ _ _ _ al = do
  dc <- diff c tree
  return $ U.cons (dc * (2 ^ al)) $ U.replicate 63 0

decodeSubsequentDCScans :: UpdateDataUnitFunc
decodeSubsequentDCScans existing _ _ _ 0 0 ah al = do
  d <- receive (ah - al)
  return $ U.cons ((U.head existing) + (d * (2 ^ al))) $ U.tail existing

decodeACScans :: UpdateDataUnitFunc
decodeACScans v c dctree actree ss se ah al = do
  l <- decodeACScans' (U.toList v) c dctree actree ss se ah al
  return $ U.fromList l

--decodeACScans' :: [Int] -> DataUnitFunc
decodeACScans' existing _ _ tree ss se ah al = do
  (cnt, b, pred, eobrun) <- existing `deepseq` get
  if eobrun == 0
    then do
      o <- helper ss middle []
      let out = beginning ++ o ++ end
      out `deepseq` return out
    else do
      put (cnt, b, pred, eobrun - 1)
      modified <- appendBitToEach al middle (-1)
      let out = beginning ++ modified ++ end
      out `deepseq` return out
  where beginning = L.take (fromIntegral ss) existing
        middle = L.take (fromIntegral $ se - ss + 1) $ L.drop (fromIntegral ss) existing
        end = L.drop (fromIntegral $ se + 1) existing
        helper k rzz lzz
         | k > se + 1 = trace "Successive elements not properly aligned" $ lift $ fail "Successive elements not properly aligned"
         | k == se + 1 && not (null rzz) = trace "rzz not null!" $ lift $ fail "rzz not null!"
         | k == se + 1 = return $ concat $ reverse lzz
         | otherwise = do
           rs <- decode tree
           case breakWord8 rs of
             (15, 0) -> do
               modified' <- appendBitToEach al rzz 15
               let modified = modified' ++ [0]
               helper (k + (fromIntegral $ length modified)) (drop (fromIntegral $ length modified) rzz) $ modified : lzz
             (r, 0) -> do
               o <- receive r
               (cnt, b, pred, _) <- get
               put (cnt, b, pred, 2 ^ r + o - 1)
               modified <- appendBitToEach al rzz (-1)
               helper (se + 1) [] $  modified : lzz
             (r, s) -> do
               o' <- receive s
               modified <- appendBitToEach al rzz $ fromIntegral r
               let ml = fromIntegral $ length modified + 1
               helper (k + fromIntegral ml) (drop ml rzz) $ [(extend o' $ fromIntegral s) * (2 ^ al)] : modified : lzz

appendBitToEach :: (Bits a, Ord a, NFData a) => Word8 -> [a] -> Int -> StateT BitState Parser [a]
appendBitToEach _ [] _ = return []
appendBitToEach _ (0 : vs) 0 = return []
appendBitToEach bitposition (0 : vs) countzeros = do
  rest <- appendBitToEach bitposition vs $ countzeros - 1
  let out = 0 : rest
  out `deepseq` return out
appendBitToEach bitposition (v : vs) countzeros = do
  b <- nextBit
  rest <- appendBitToEach bitposition vs countzeros
  let d = (fromIntegral b) * (2 ^ (fromIntegral bitposition))
  let out = (if v < 0 then v - d else v + d) : rest
  out `deepseq` return out
