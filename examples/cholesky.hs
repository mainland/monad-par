{-
 - Intel Concurrent Collections for Haskell
 - Copyright (c) 2010, Intel Corporation.
 -
 - This program is free software; you can redistribute it and/or modify it
 - under the terms and conditions of the GNU Lesser General Public License,
 - version 2.1, as published by the Free Software Foundation.
 -
 - This program is distributed in the hope it will be useful, but WITHOUT
 - ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 - FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for
 - more details.
 -
 - You should have received a copy of the GNU Lesser General Public License along with
 - this program; if not, write to the Free Software Foundation, Inc., 
 - 51 Franklin St - Fifth Floor, Boston, MA 02110-1301 USA.
 -
 -}
{-# LANGUAGE ExistentialQuantification
   , ScopedTypeVariables
   , BangPatterns
   , NamedFieldPuns 
   , RecordWildCards
   , FlexibleInstances
   , DeriveDataTypeable
   , TypeSynonymInstances
   , CPP
  #-}

-- Author: Chih-Ping Chen
-- Modified by Ryan Newton.

-- This program uses monad-par to do cholesky transformation.  

-- Description
-- -----------
-- Given a symmetric positive definite matrix A, the Cholesky decomposition is
-- a lower triangular matrix L such that A=L.L^(T). 

-- Usage
-- -----

-- The command line is:

-- cholesky n b filename
-- 	 n :	input SPD matrix size
-- 	 b : 	block/tile size
-- 	 filename: input matrix file name

-- Several sample input files are provided. m6.in is a 6x6 matrix (n=6).
-- Input_matrix.zip contains the files m50.in, m100.in, m500.in, and m1000.in with
-- corresponding 'n' of 50, 100, 500, and 1000.

-- e.g.
-- cholesky 1000 50 m1000.in 4
-- cholesky v 6 2 m6.in

-- The input SPD matrix is read from the file specified. The output will be a
-- lower triangular matrix. 

import Data.Int
import qualified Data.List as List
import qualified Data.Array.Unboxed as Array
import Data.Array.IO
import Data.Array.MArray
import Debug.Trace
import System.Posix.Files
import System.Environment
import System.IO
import System.IO.Unsafe
import Data.Map
import Data.IORef

import Control.DeepSeq
import Data.Time.Clock -- Not in 6.10

import Control.Monad
import Control.Monad.Par

timeit io = 
    do strt <- getCurrentTime
       io       
       end  <- getCurrentTime
       return (diffUTCTime end strt)

-- The type of the input/output array.
type Matrix = Array.Array (Int, Int) Float

-- A matrix is divided into "Tile"s, and carries intermediate results
-- of the computation.
type Tile = IOUArray  (Int, Int) Float

-- Tile3D allows us to refer to a PVar associated with a tile. The first
-- two dimensions of the index are the coordinates of the tile in the matrix.
-- The last dimension is the "generation" dimension. I.e., a (PVar Tile) mapped
-- by (i, j, k+1) is the next generation of the (PVar Tile) mapped by (i, j, k).
type Tiles3D = Map (Int, Int, Int) (PVar Tile)

instance NFData Tile where
    rnf x = unsafePerformIO $
                do bounds <- getBounds x
                   elems  <- getElems x
                   _ <- return $ rnf (bounds, elems)
                   return ()

parMap_ :: (a -> Par ()) -> [a] -> Par ()
parMap_ f xs = mapM (spawn . f) xs >> return ()

getTileV :: (Int, Int, Int) -> Tiles3D -> PVar Tile
getTileV triplet tiles =
    findWithDefault (error "This can't be happening...") triplet tiles

-- This kicks off cholesky factorization on the diagonal tiles.
s0Compute :: PVar Tiles3D -> Int -> Int -> Par ()
s0Compute lkjiv p b =
    do lkji <- get lkjiv
       parMap_ (s1Compute lkji p b) [0..p-1]

-- This does the cholesky factorization on the a diagonal tile, and
-- kicks off triangular system solve on the tiles that are below and 
-- on the same column as the diagonal tile.
s1Compute :: Tiles3D -> Int -> Int -> Int -> Par ()
s1Compute lkji p b k = 
    do
       -- Read the tile:
       aBlock <- get $ getTileV (k, k, k) lkji
       -- Write an output tile:
       put (getTileV (k, k, k+1) lkji) (s1Core aBlock b)
       -- Do triangular solves on the tiles with the same column number
       parMap_ (s2Compute lkji b) [(k,j) | j <- [k+1..p-1]]
    where s1Core aBlock b = unsafePerformIO $ 
                            do lBlock <- newArray ((0,0), (b-1,b-1)) 0.0
                               forM_ [0..b-1] (outer aBlock lBlock b)
                               return lBlock
          outer aBlock lBlock b kb = do base <- readArray aBlock (kb,kb)
                                        writeArray lBlock (kb,kb) (sqrt base)
                                        forM_ [kb+1 .. b-1] (inner1 aBlock lBlock kb)
                                        forM_ [kb+1 .. b-1] (inner2 aBlock lBlock kb b)
          inner1 aBlock lBlock kb jb = do base1 <- readArray aBlock (jb,kb)
                                          base2 <- readArray lBlock (kb,kb)
                                          writeArray lBlock (jb,kb) (base1 /base2)
          inner2 aBlock lBlock kb b jbb = do forM_ [kb+1 .. b-1] (inner3 aBlock lBlock jbb kb)
          inner3 aBlock lBlock jbb kb ib = do base1 <- readArray aBlock (ib, jbb)
                                              base2 <- readArray lBlock (ib, kb)
                                              base3 <- readArray lBlock (jbb, kb)
                                              writeArray aBlock (ib,jbb) (base1 - base2 * base3)

-- This does the triangular system solve on a tile T, and
-- kicks off the symmetric rank-k update on the tiles that 
-- are to the right and on the same row as T. 
s2Compute :: Tiles3D -> Int -> (Int, Int) -> Par ()
s2Compute lkji b (k, j) =
    do 
       aBlock <- get $ getTileV (j,k,k) lkji
       liBlock <- get $ getTileV (k,k,k+1) lkji
       put (getTileV (j,k,k+1) lkji) (s2Core aBlock liBlock b)
       parMap_ (s3Compute lkji b) [(k, j, i) | i <- [k+1..j]]
    where s2Core aBlock liBlock b = unsafePerformIO $
                                    do loBlock <- newArray ((0,0),(b-1,b-1)) 0.0
                                       forM_ [0..b-1] (outer aBlock liBlock loBlock b)
                                       return loBlock
          outer aBlock liBlock loBlock b kb = do forM_ [0..b-1] (inner1 aBlock liBlock loBlock kb)
                                                 forM_ [kb+1..b-1] (inner2 aBlock liBlock loBlock b kb)
          inner1 aBlock liBlock loBlock kb ib = do base1 <- readArray aBlock (ib,kb)
                                                   base2 <- readArray liBlock (kb,kb)
                                                   writeArray loBlock (ib,kb) (base1 / base2)
          inner2 aBlock liBlock loBlock b kb jb = do forM_ [0..b-1] (inner3 aBlock liBlock loBlock kb jb)
          inner3 aBlock liBlock loBlock kb jb ib = do base1 <- readArray aBlock (ib,jb)
                                                      base2 <- readArray liBlock (jb,kb)
                                                      base3 <- readArray loBlock (ib,kb)
                                                      writeArray aBlock (ib,jb) (base1 - (base2 * base3))
                                                      

-- This computes the symmetric rank-k update on a tile.
s3Compute :: Tiles3D -> Int -> (Int, Int, Int) -> Par ()
s3Compute lkji b (k,j,i) | i == j =
    do 
       aBlock <- get $ getTileV (j,i,k) lkji
       l2Block <- get $ getTileV (j,k,k+1) lkji
       put (getTileV (j,i,k+1) lkji) (s3Core aBlock l2Block b)
--       pval lkji
       return ()
    where s3Core aBlock l2Block b = unsafePerformIO $
                                    do forM_ [0..b-1] (outer aBlock l2Block b)
                                       return aBlock
          outer aBlock l2Block b jb = do forM_ [0..b-1] (inner1 aBlock l2Block b jb)
          inner1 aBlock l2Block b jb kb = do base <- readArray l2Block (jb,kb) 
                                             forM_ [jb..b-1] (inner2 aBlock l2Block jb kb (-base))
          inner2 aBlock l2Block jb kb temp ib = do base1 <- readArray aBlock (ib,jb)
                                                   base2 <- readArray l2Block (ib,kb)
                                                   writeArray aBlock (ib,jb) (base1 + temp * base2)
       
s3Compute lkji b (k,j,i) | otherwise =
    do 
       aBlock <- get $ getTileV (j,i,k) lkji
       l2Block <- get $ getTileV (i,k,k+1) lkji
       l1Block <- get $ getTileV (j,k,k+1) lkji
       put (getTileV (j,i,k+1) lkji) (s3Core aBlock l1Block l2Block b)
       return ()
    where s3Core aBlock l1Block l2Block b = unsafePerformIO $
                                            do forM_ [0..b-1] (outer aBlock l1Block l2Block b)
                                               return aBlock
          outer aBlock l1Block l2Block b jb = do forM_ [0..b-1] (inner1 aBlock l1Block l2Block b jb)
          inner1 aBlock l1Block l2Block b jb kb = do base <- readArray l2Block (jb,kb) 
                                                     forM_ [0..b-1] (inner2 aBlock l1Block jb kb (-base))
          inner2 aBlock l1Block jb kb temp ib = do base1 <- readArray aBlock (ib,jb)
                                                   base2 <- readArray l1Block (ib,kb)
                                                   writeArray aBlock (ib,jb) (base1 + temp * base2)

-- initLkji initialize the (PVar Tile) map using the input array.
initLkji :: Matrix -> Int -> Int -> Int -> Par (PVar Tiles3D)    
initLkji arrA n p b = 
    let tile i j = unsafePerformIO $ newListArray ((0,0),(b-1,b-1)) (tileList i j)
        tileList i j = [ arrA Array.! (i * b + ii, j * b + jj) | ii <- [0..b-1], jj <-[0..b-1]]
        fn c (i, j, k) | k == 0 = 
            do mv <- c
               m <- get mv
               tv <- pval $ tile i j
               pval $ insert (i, j, k) tv m
        fn c (i, j, k) | otherwise = 
            do mv <- c
               m <- get mv
               tv <- new
               pval $ insert (i, j, k) tv m
    in foldl fn (pval empty)  [(i, j, k) | i <- [0..p-1], j <- [0..i], k <- [0..j+1]]           
     

-- composeResult collect the tiles with the final results back into one single matrix.    
composeResult :: Tiles3D -> Int -> Int -> Int -> Par Matrix    
composeResult lkji n p b =
    do assocs <- sequence [ grab i ib j | i <- [0..p-1], ib <- [0..b-1], j <- [0..i]]
       return $ Array.array ((0,0),(n-1,n-1)) (concat assocs)
    where grab i ib j = if (i == j) then
                           do matOut <- get $ getTileV (i,j,j+1) lkji
                              compose1 matOut 
                        else
                           do matOut <- get $ getTileV (i,j,j+1) lkji
                              compose2 matOut
                        where compose1 matOut = do forM [0..ib] (compose11 matOut)
                              compose11 matOut jb = let elem = unsafePerformIO $
                                                               do readArray matOut (ib,jb)
                                                    in return ((i*b+ib,j*b+jb),elem)
                              compose2 matOut = do forM [0..b-1] (compose11 matOut)   

{-# INLINE for_ #-} 
for_ start end fn | start > end = error "for_: start is greater than end"
for_ start end fn = loop start
 where 
  loop !i | i == end  = return () 
          | otherwise = do fn i; loop (i+1)

run :: Int -> Int -> Matrix -> Matrix
run n b arrA = 
    let p = n `div` b
    in 
        runPar $
        do 
            lkjiv <- initLkji arrA n p b
            _ <- s0Compute lkjiv p b
            lkji' <- get lkjiv
            composeResult lkji' n p b

main = 
    do ls <- getArgs 
       let [n, b, fname] = 
            case ls of 
              []           -> ["6",     "2", "cholesky_matrix6.dat"]

              -- To get more data try this:
	      -- wget http://people.csail.mit.edu/newton/haskell-cnc/datasets/cholesky_matrix_data.tbz

              ["medium"]   -> ["500",  "50", "cholesky_matrix500.dat"]
              ["big"]      -> ["1000", "50", "cholesky_matrix1000.dat"]
	      [_,_,_] -> ls

       bool <- fileExist fname
       let fname' = if bool then fname else "examples/"++fname
    
       ref <- newIORef undefined
       let meaningless_write !val = writeIORef ref val

       t1 <- getCurrentTime
       putStrLn "Begin reading from disk..."
       arrA <- initMatrix (read n) fname'             
#if 0
       let ((sx,sy),(ex,ey)) = Array.bounds arrA
       for_ sx (ex+1) $ \i ->
         for_ sy (ey+1) $ \j ->
	     meaningless_write$ arrA Array.! (i,j)
       t2 <- getCurrentTime
#endif
       t2 <- case deepseq arrA () of _ -> getCurrentTime 
--       t2 <- arrA `deepseq` getCurrentTime
       -- deepseq arrA $ 
       putStrLn $" ... ArrA read from disk: time " ++ show (diffUTCTime t2 t1)
       hFlush stdout

       --putStrLn $ show $ arrA
       --putStrLn "Making sure evaluation of arrA is forced..."
       --case deepseq arrA arrA of _ -> putStrLn "Finished."

       arrB <- return $ run (read n) (read b) arrA
       --putStrLn $ show $ [((i,j),arrB Array.! (i,j)) | i <-[0..(read n)-1], j<-[0..i]]

       putStrLn "Making sure evaluation of arrB is forced..."
       --putStrLn $ show $ [((i,j),arrB Array.! (i,j)) | i <-[0..(read n)-1], j<-[0..i]]
#if 1
       for_ 0 (read n) $ \i ->
         for_ 0 (i+1) $ \j ->
	    -- This first approach didn't work:
	    --case arrB Array.! (i,j) of _ -> return ()
	     do meaningless_write$ arrB Array.! (i,j)
       t3 <- getCurrentTime
#endif
-- FIXME: Using deepseq here seems to delay the evaluation to the reference of 
--       t3 <- case deepseq arrB () of _ -> getCurrentTime
--       t3 <- arrB `deepseq` getCurrentTime
       putStrLn$ "Finished: eval time "++ show (diffUTCTime t3 t2)

       putStrLn$ "SELFTIMED " ++ show ((fromRational $ toRational $ diffUTCTime t3 t2) :: Double)
       t4 <- getCurrentTime
       val <- readIORef ref
       putStrLn$ "Last value: " ++ show (arrB Array.! (read n-1, read n-1))
       t5 <- getCurrentTime
       putStrLn$ "SELFTIMED' " ++ show ((fromRational $ toRational $ diffUTCTime t5 t4) :: Double) 

initMatrix :: Int -> [Char] -> IO Matrix
initMatrix n fname = 
    do fs <- readFile fname
       return $ Array.listArray ((0,0), (n-1, n-1)) 
		                (List.cycle $ List.map read (words fs))
	   