{-# LANGUAGE   DeriveDataTypeable
             , ScopedTypeVariables
             , FlexibleInstances
             , FlexibleContexts
              #-}
{-# OPTIONS -IControl/Workflow       #-}

{- | This module contains monadic combinators that express some workflow patterns.
see the docAprobal.hs example included in the package


EXAMPLE:

This fragment below describes the approbal procedure of a document.
First the document reference is sent to a list of bosses trough a queue.
ithey return a boolean in a  return queue ( askUser)
the booleans are summed up according with a monoid instance (sumUp)

if the resullt is false, the correctWF workflow is executed
If the result is True, the pipeline continues to the next stage  (checkValidated)

the next stage is the same process with a new list of users (superbosses).
There is a timeout of seven days. The result of the users that voted is summed
up according with the same monoid instance

if the result is true the document is added to the persistent list of approbed documents
if the result is false, the document is added to the persistent list of rejectec documents (checlkValidated1)

The program can be interrupted at any moment. The Workflow monad will restartWorkflows
it at the point where it was interrupted.

@docApprobal :: Document -> Workflow IO ()
docApprobal doc =  `getWFRef` \>>= docApprobal1


docApprobal1 rdoc=
    return True \>>=
    log \"requesting approbal from bosses\" \>>=
    `sumUp` 0 (map (askUser doc rdoc) bosses)  \>>=
    checkValidated \>>=
    log \"requesting approbal from superbosses or timeout\"  \>>=
    `sumUp` (7*60*60*24) (map(askUser doc rdoc) superbosses) \>>=
    checkValidated1


askUser _ _ user False = return False
askUser doc rdoc user  True =  do
      `step` $ `push` (quser user) rdoc
      `logWF` ("wait for any response from the user: " ++ user)
      `step` . `pop` $ qdocApprobal (title doc)

log txt x = `logWF` txt >> return x

checkValidated :: Bool -> `Workflow` IO Bool
checkValidated  val =
      case val of
        False -> correctWF (title doc) rdoc >> return False
        _     -> return True


checkValidated1 :: Bool -> Workflow IO ()
checkValidated1 val = step $ do
      case  val of
        False -> `push` qrejected doc
        _     -> `push` qapproved doc
      mapM (\u ->deleteFromQueue (quser u) rdoc) superbosses@

-}

module Control.Workflow.Patterns(
-- * Low level combinators
split, merge, select,
-- * High level conbinators
vote, sumUp, Select(..)
) where
import Control.Concurrent.STM
import Data.Monoid
import Control.Concurrent.MonadIO
import qualified Control.Monad.CatchIO as CMC
import Control.Workflow.Stat
import Control.Workflow
import Data.Typeable
import Prelude hiding (catch)
import Control.Monad
import Control.Exception.Extensible (Exception,SomeException)
import Data.RefSerialize
import Control.Workflow.Stat

import Data.TCache
import Debug.Trace


newtype ActionWF a= ActionWF (WFRef(Maybe a))  -- (WFRef (String, Bool))

-- | spawn a list of independent workflow 'actions' with a seed value 'a'
-- The results are reduced by `merge` or `select`
split :: ( Typeable b
           , Serialize b
           , HasFork io
           , CMC.MonadCatchIO io)
          => [a -> Workflow io b] -> a  -> Workflow io [ActionWF b]
split actions a = mapM (\ac ->
     do
         mv <- newWFRef Nothing
         fork  (ac a >>= \v -> (step . liftIO . atomicallySync .  writeWFRef mv . Just) v )

         return  $ ActionWF mv )

     actions



-- | wait for the results and apply the cond to produce a single output in the Workflow monad
merge :: ( MonadIO io
           , Typeable a
           , Typeable b
           , Serialize a, Serialize b)
           => ([a] -> io b) -> [ActionWF a] -> Workflow io b
merge  cond results= step $ mapM (\(ActionWF mv ) -> readWFRef1 mv ) results >>=  cond -- !> "cond"

readWFRef1 :: ( MonadIO io
              , Serialize a
              , Typeable a)
              => WFRef (Maybe a) -> io  a
readWFRef1 r = liftIO . atomically $ do

      mv <- readWFRef r

      case mv of
       Just(Just v)  -> return v -- !> "return v"
       Just Nothing  -> retry -- !> "retry"
       Nothing -> error $ "readWFRef1: workflow not found "++ show r


data Select
            = Select
            | Discard
            | FinishDiscard
            | FinishSelect
            deriving(Typeable, Read, Show)

instance Exception Select

-- | select the outputs of the workflows produced by `split` constrained within a timeout.
-- The check filter, can select , discard or finish the entire computation before
-- the timeout is reached. When the computation finalizes, it kill all
-- the pending workflows and return the list of selected outputs
-- the timeout is in seconds and is no limited to a single execution, so it can proceed for years.
--
-- This is necessary for the modelization of real-life institutional cycles such are political elections
-- A timeout of 0 means no timeout.
select ::
         ( Serialize a
         , Serialize [a]
         , Typeable a
         , HasFork io
         , CMC.MonadCatchIO io)
         => Integer
         -> (a ->   io Select)
         -> [ActionWF a]
         -> Workflow io [a]
select timeout check actions=   do
 res  <- newMVar []
 flag <- getTimeoutFlag timeout
 parent <- myThreadId
 checThreads <- newEmptyMVar
 count <- newMVar 1
 let process = do
        let check'  (ActionWF ac ) =  do
               r <- readWFRef1 ac
               b <- check r
               case b of
                  Discard -> return ()
                  Select  -> addRes r
                  FinishDiscard -> do
                       throwTo parent FinishDiscard
                  FinishSelect -> do
                       addRes r
                       throwTo parent FinishDiscard

               n <- CMC.block $ do
                     n <- takeMVar count
                     putMVar count (n+1)
                     return n      !> ("SELECT" ++ show n)

               if ( n == length actions)
                     then throwTo parent FinishDiscard
                     else return ()

              `CMC.catch` (\(e :: Select) -> throwTo parent e)


        ws <- mapM ( fork . check') actions
        putMVar checThreads  ws

        liftIO $ atomically $ do
           v <- readTVar flag -- wait fo timeout
           case v of
             False -> retry
             True  -> return ()
        throw FinishDiscard
        where

        addRes r=  CMC.block $ do
            l <- takeMVar  res
            putMVar  res $ r : l

 let killall  = do
       ws <- readMVar checThreads
       liftIO $ mapM_ killThread ws !> "KILLALL"

 step $ CMC.catch   process -- (WF $ \s -> process >>= \ r -> return (s, r))
              (\(e :: Select)-> do
                 readMVar res
                 )
       `CMC.finally`   killall



justify str Nothing = error str
justify _ (Just x) = return x

-- | spawn a list of workflows and reduces the results according with the 'comp' parameter within a given timeout
--
-- @
--   vote timeout actions comp x=
--        split actions x >>= select timeout (const $ return Select)  >>=  comp
-- @
vote
      :: ( Serialize b
         , Serialize [b]
         , Typeable b
         , HasFork io
         , CMC.MonadCatchIO io)
      => Integer
      -> [a -> Workflow io  b]
      -> ([b] -> Workflow io c)
      -> a
      -> Workflow io c
vote timeout actions comp x=
  split actions x >>= select timeout (const $ return Select)  >>=  comp


-- | sum the outputs of a list of workflows  according with its monoid definition
--
-- @ sumUp timeout actions = vote timeout actions (return . mconcat) @
sumUp
  :: ( Serialize b
     , Serialize [b]
     , Typeable b
     , Monoid b
     , HasFork io
     , CMC.MonadCatchIO io)
     => Integer
     -> [a -> Workflow io b]
     -> a
     -> Workflow io b
sumUp timeout actions = vote timeout actions (return . mconcat)




main= do
  syncWrite SyncManual
  r <- exec1 "sumup" $ sumUp 0 [f 1, f 2] "0"
  print r

  `CMC.catch` \(e::SomeException) -> syncCache !> "syncCache"


f :: Int -> String -> Workflow IO String
f n s= step (  threadDelay ( 5000000 * n)) >> return ( s ++"1")


main2=do
 syncWrite SyncManual
 exec1 "split" $ split  (take 10 $ repeat (step . print)) "hi" >>= merge (const $ return True)


main3=do
--   syncWrite SyncManual
   refs <- exec1 "WFRef" $ do

                 refs <-  replicateM 20  $ newWFRef  Nothing --"bye initial valoe"
                 mapM (\r -> fork $ unsafeIOtoWF $ atomically $ writeWFRef r $ Just "hi final value") refs


                 return refs
   mapM (\r ->  readWFRef1 r >>= print) refs



