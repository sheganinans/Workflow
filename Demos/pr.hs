
module Main where
import Control.Workflow
import Control.Workflow.Stat

import Data.TCache
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)
import Control.Concurrent
import qualified Data.ByteString.Lazy.Char8 as B



main2= do
   Just stat <- getWFHistory "docApprobal" "Doc#title"
   B.putStrLn $ showHistory stat
   withResource stat $ \(Just stat) -> stat{recover= False}
   syncCache



main= do
   refs <- exec1 "WFRef" $ do
                 step $ return (1 :: Int)
                 (ref,s) <- stepWFRef $ return "bye initial valoe"
                 step $ return (3 :: Int)

                 return ref

   atomically $ writeWFRef refs "hi final value"
   s <- atomically $   readWFRef refs
   print s
   Just stat <- getWFHistory "WFRef" ()
   B.putStrLn $ showHistory stat
   syncCache
   atomically flushAll
   Just stat <- getWFHistory "WFRef" ()
   B.putStrLn $ showHistory stat
   s <- atomically $   readWFRef refs
   print s



