{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -Wall -fno-warn-orphans #-}
module Control.Monad.Par.Meta.HotVar.IORef ( HotVar
                                           , modifyHotVar
                                           , modifyHotVar_
                                           , newHotVar
                                           , readHotVar
                                           , readHotVarRaw
                                           , writeHotVar
                                           , writeHotVarRaw
                                           ) where

import Data.IORef

newHotVar      :: a -> IO (HotVar a)
modifyHotVar   :: HotVar a -> (a -> (a,b)) -> IO b
modifyHotVar_  :: HotVar a -> (a -> a) -> IO ()
writeHotVar    :: HotVar a -> a -> IO ()
readHotVar     :: HotVar a -> IO a

type HotVar a = IORef a
newHotVar     = newIORef
modifyHotVar  = atomicModifyIORef
modifyHotVar_ v fn = atomicModifyIORef v (\a -> (fn a, ()))
readHotVar    = readIORef
writeHotVar   = writeIORef
instance Show (HotVar a) where 
  show _ = "<ioref>"

readHotVarRaw  :: HotVar a -> IO a
writeHotVarRaw :: HotVar a -> a -> IO ()
readHotVarRaw  = readHotVar
writeHotVarRaw = writeHotVar
