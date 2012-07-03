{-# LANGUAGE  OverlappingInstances
            , UndecidableInstances
            , ExistentialQuantification
            , ScopedTypeVariables
            , MultiParamTypeClasses
            , FlexibleInstances
            , FlexibleContexts
            , TypeSynonymInstances
            , DeriveDataTypeable
            , RecordWildCards
            , BangPatterns
          #-}
{-# OPTIONS -IControl/Workflow       #-}


{- | A workflow can be seen as a persistent thread.
The workflow monad writes a log that permit to restore the thread
at the interrupted point. `step` is the (partial) monad transformer for
the Workflow monad. A workflow is defined by its name and, optionally
by the key of the single parameter passed. The primitives for starting workflows
also restart the interrupted workflow when it has been in execution previously.


A small example that print the sequence of integers in te console
if you interrupt the progam, when restarted again, it will
start from the last  printed number

@module Main where
import Control.Workflow
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)

mcount n= do `step` $  do
                       putStr (show n ++ \" \")
                       hFlush stdout
                       threadDelay 1000000
             mcount (n+1)
             return () -- to disambiguate the return type

main= `exec1`  \"count\"  $ mcount (0 :: Int)@

>runghc demos\sequence.hs
0 1 2 3
CTRL-C Pressed
>runghc demos\sequence.hs
3 4 5 6 7
CTRL-C Pressed
C:\Users\agocorona\Documents\Dropbox\Haskell\devel\Workflow>runghc demos\sequenc
e.hs
7 8 9 10 11
...

The program continue restart by recovering the sequence.

As you can see, some side effect can be re-executed after recovery if
the log is not complete. This may happen after an unexpected shutdown (in this case)
or due to an asynchronous log writing policy. (see `syncWrite`)

When the step results are big and complex, use the "Data.RefSerialize" package to define  the (de)serialization instances
The log size will be reduced. printWFHistory` method will print the structure changes
in each step.

If instead of `RefSerialize`, you use read and show instances, there will
 be no reduction. but still it will work, and the log will be readable for debugging purposes.
 The RefSerialize istance is automatically derived from Read, Show instances.

Data.Binary instances are also fine for serialization. To use Binary, just define a binary instance
of your data by using `showpBinary` and `readpBinary`.

Within the RefSerialize instance of a structure, you can freely mix
Show,Read  RefSerialize and Data Binary instances.


-}

module Control.Workflow

(
  Workflow --    a useful type name
, WorkflowList
, PMonadTrans (..)
, MonadCatchIO (..)
, throw
, Indexable(..)
-- * Start/restart workflows
, start
, exec
, exec1d
, exec1
, wfExec
, startWF
, restartWorkflows
, WFErrors(..)
-- * Lifting to the Workflow monad
, step
--, while
--, label
--, stepControl
--, stepDebug
, unsafeIOtoWF
-- * References to intermediate values in the workflow log
, WFRef
, newWFRef
, stepWFRef
, readWFRef
-- * state manipulation
, writeWFRef
, moveState
-- * Workflow inspect
, waitWFActive
, getAll
--, getStep
, safeFromIDyn
, getWFKeys
, getWFHistory
, waitFor
, waitForSTM
-- * Persistent timeouts
, waitUntilSTM
, getTimeoutFlag
, withTimeout
, withKillTimeout
-- * Trace logging
, logWF
-- * Termination of workflows
, clearRunningFlag
, killThreadWF
, killWF
, delWF
, killThreadWF1
, killWF1
, delWF1
, delWFHistory
, delWFHistory1
-- * Log writing policy
, syncWrite
, SyncMode(..)
-- * Print log history
, showHistory
, isInRecover
)

where

import Prelude hiding (catch)
import System.IO.Unsafe
import Control.Monad(when,liftM)
import qualified Control.Exception as CE (Exception,AsyncException(ThreadKilled), SomeException, ErrorCall, throwIO, handle,finally,catch,block,unblock)
import Control.Concurrent (forkIO,threadDelay, ThreadId, myThreadId, killThread)
import Control.Concurrent.STM
import GHC.Conc(unsafeIOToSTM)
import GHC.Base (maxInt)


import  Data.ByteString.Lazy.Char8 as B hiding (index)
import Data.ByteString.Lazy  as BL(putStrLn)
import Data.List as L
import Data.Typeable
import System.Time
import Control.Monad.Trans
import Control.Concurrent.MonadIO(HasFork(..),MVar,newMVar,takeMVar,putMVar,readMVar)


import System.IO(hPutStrLn, stderr)
import Data.List(elemIndex)
import Data.Maybe
import Data.IORef
import System.IO.Unsafe(unsafePerformIO)
import  Data.Map as M(Map,fromList,elems, insert, delete, lookup,toList, fromList,keys)
import qualified Control.Monad.CatchIO as CMC
import qualified Control.Exception.Extensible as E

import Data.TCache
import Data.TCache.Defs
import Data.RefSerialize
import Control.Workflow.IDynamic
import Unsafe.Coerce
import System.Mem.StableName
import Control.Workflow.Stat

--import Debug.Trace
--a !> b= trace b a


type Workflow m = WF  Stat  m   -- not so scary

type WorkflowList m a b= [(String,  a -> Workflow m  b) ]


instance Monad m =>  Monad (WF  s m) where
    return  x = WF (\s ->  return  (s, x))
    WF g >>= f = WF (\s -> do
                (s1, x) <- g s
                let WF fun=  f x
                fun s1)



instance (Monad m,Functor m)  => Functor (Workflow m ) where
  fmap f (WF g)= WF (\s -> do
                (s1, x) <- g s
                return (s1, f x))

tvRunningWfs =  getDBRef $ keyRunning :: DBRef Stat



-- | executes a  computation inside of the workflow monad whatever the monad encapsulated in the workflow.
-- Warning: this computation is executed whenever
-- the workflow restarts, no matter if it has been already executed previously. This is useful for intializations or debugging.
-- To avoid re-execution when restarting  use:   @'step' $  unsafeIOtoWF...@
--
-- To perform IO actions in a workflow that encapsulates an IO monad, use step over the IO action directly:
--
--        @ 'step' $ action @
--
-- instead   of
--
--      @  'step' $ unsafeIOtoWF $ action @
unsafeIOtoWF ::   (Monad m) => IO a -> Workflow m a
unsafeIOtoWF x= let y= unsafePerformIO ( x >>= return)  in y `seq` return y


{- |  PMonadTrans permits |to define a partial monad transformer. They are not defined for all kinds of data
but the ones that have instances of certain classes.That is because in the lift instance code there are some
hidden use of these classes.  This also may permit an accurate control of effects.
An instance of MonadTrans is an instance of PMonadTrans
-}
class PMonadTrans  t m a  where
      plift :: Monad m => m a -> t m a



-- | plift= step
instance  (Monad m
          , MonadIO m
          , Serialize a
          , Typeable a)
          => PMonadTrans (WF Stat)  m a
          where
     plift = step

-- |  An instance of MonadTrans is an instance of PMonadTrans
instance (MonadTrans t, Monad m) => PMonadTrans t m a where
    plift= Control.Monad.Trans.lift

--- | handle with care: this instance  will force
-- the unwanted execution at recovery of every liftted IO procedure
-- better use 'step . liftIO'  instead of 'liftIO'
instance MonadIO m => MonadIO (WF Stat  m) where
   liftIO= unsafeIOtoWF


{- | adapted from MonadCatchIO-mtl. Workflow need to express serializable constraints about the  returned values,
so the usual class definitions for lifting IO functions are not suitable.
-}

class  MonadCatchIO m a where
    -- | Generalized version of 'E.catch'
    catch   :: E.Exception e => m a -> (e -> m a) -> m a

    -- | Generalized version of 'E.block'
    block   :: m a -> m a

    -- | Generalized version of 'E.unblock'
    unblock :: m a -> m a



-- | Generalized version of 'E.throwIO'
throw :: (MonadIO m, E.Exception e) => e -> m a
throw = liftIO . E.throwIO





instance (Serialize a
         , Typeable a,MonadIO m, CMC.MonadCatchIO m)
         => MonadCatchIO (WF Stat m) a where
   catch exp exc = do
     expwf <- step $ getTempName
     excwf <- step $ getTempName
     step $ do
        ex <- CMC.catch (exec1d expwf exp >>= return . Right
                                           ) $ \e-> return $ Left e

        case ex of
           Right r -> return r                -- All right
           Left  e ->exec1d excwf (exc e)
                         -- An exception occured in the main workflow
                         -- the exception workflow is executed




   block   exp=WF $ \s -> CMC.block (st exp $ s)

   unblock exp=  WF $ \s -> CMC.unblock (st exp $ s)

data WFInfo= WFInfo{ name :: String
                      , finished :: Bool
                      , haserror ::  Maybe WFErrors }
                      deriving  (Typeable,Read, Show)



instance  (HasFork io, MonadIO io
          , CMC.MonadCatchIO io)

          => HasFork (WF Stat  io) where
   fork f = do
    (r,info@(WFInfo str finished status)) <- stepWFRef $ getTempName >>= \n -> return(WFInfo n False  Nothing)

    WF $ \s -> do
        th <- if finished then fork $ return()
               else
                fork $
                     exec1 str f >> labelFinish r str Nothing
                        `CMC.catch` \(e :: E.SomeException) -> do
                                     liftIO . atomicallySync $ writeWFRef r (WFInfo str True . Just . WFException $ show e)   !> ("ERROR *****"++show e)
                                     killWF1 $ keyWF str ()


        return (s,th)
    where
    labelFinish r str err= liftIO . atomicallySync $ writeWFRef r (WFInfo str True err)   !> "finished"


-- | start or restart an anonymous workflow inside another workflow.
--  Its state is deleted when finished and the result is stored in
--  the parent's WF state.
wfExec
  :: (Indexable a, Serialize a, Typeable a
  ,  CMC.MonadCatchIO m, MonadIO m)
  => Workflow m a -> Workflow m  a
wfExec f= do
      str <- step $ getTempName
      step $ exec1 str f

-- | a version of exec1 that deletes its state after complete execution or thread killed
exec1d :: (Serialize b, Typeable b
          ,MonadIO m, CMC.MonadCatchIO m)
          => String ->  (Workflow m b) ->  m  b
exec1d str f= do
   r <- exec1 str  f
   delit
   return r
  `CMC.catch` (\e@CE.ThreadKilled ->  delit >> throw e)

   where
   delit=  do
     delWF str ()




-- | a version of exec with no seed parameter.
exec1 ::  ( Serialize a, Typeable a
          , Monad m, MonadIO m, CMC.MonadCatchIO m)
          => String ->  Workflow m a ->   m  a

exec1 str f=  exec str (const f) ()




-- | start or continue a workflow with exception handling
-- | the workflow flags are updated even in case of exception
-- | `WFerrors` are raised as exceptions
exec :: ( Indexable a, Serialize a, Serialize b, Typeable a
        , Typeable b
        , Monad m, MonadIO m, CMC.MonadCatchIO m)
          => String ->  (a -> Workflow m b) -> a ->  m  b
exec str f x =
       (do
            v <- getState str f x
            case v of
              Right (name, f, stat) -> do
                 r <- runWF name (f x) stat
                 return  r
              Left err -> CMC.throw err)
     `CMC.catch`
       (\(e :: CE.SomeException) -> liftIO $ do
             let name=  keyWF str x
             clearRunningFlag name  --`debug` ("exception"++ show e)
             CMC.throw e )




mv :: MVar Int
mv= unsafePerformIO $ newMVar 0

getTempName :: MonadIO m => m String
getTempName= liftIO $ do
     seq <- takeMVar mv
     putMVar mv (seq + 1)
     TOD t _ <- getClockTime
     return $ "anon"++ show t ++ show seq




---- | Permits the modification of the workflow state by the procedure being lifted
---- if the boolean value is True. This is used internally for control purposes
--stepControl :: ( Monad m
--        , MonadIO m
--        , Serialize a
--        , Typeable a)
--        =>   m a
--        ->  Workflow m a
--stepControl= stepControl1 True


-- | Lifts a monadic computation  to the WF monad, and provides  transparent state loging and  resuming the computation
-- Note: Side effect can be repeated at recovery time if the log was not complete before shut down
-- see the integer sequence example, above.
step :: ( Monad m
        , MonadIO m
        , Serialize a
        , Typeable a)
        =>   m a
        ->  Workflow m a

step  mx= WF(\s -> do
        let stat= state s
        let versionss= versions s !> "vvvvvvvvvvvvvvvvvvv"
                                  !> (unpack $ runW $ showp $  versions s)
                                  !> (show $ references s)
                                  !> (show $ "recover="++ show( recover s))
                                  !> "^^^^^^^^^^^^^^^^^^^^"
        if recover s && not (L.null versionss)
          then
            return (s{versions=L.tail versionss }, fromIDyn $ L.head versionss )
          else do
            let ref= self s
            liftIO $ atomically $ do
              s' <- readDBRef ref `justifyM` error ("step: not found: "++ wfName s)
              writeDBRef ref s'{recover= False,references= references s}
            stepExec  ref  mx)

stepExec  sref  mx= do
            x' <- mx

            liftIO . atomicallySync $ do
              s <- readDBRef  sref  >>= return . fromMaybe (error $ "step: readDBRef: not found:" ++ keyObjDBRef sref)

              let versionss= versions s
                  dynx=  toIDyn x'
                  ver= dynx: versionss
                  s'= s{ recover= False, versions =  ver, state= state s+1}

              writeDBRef sref s'

              return (s', x')

isInRecover :: Monad m => Workflow m Bool
isInRecover = WF(\s@Stat{..} ->
     if recover  && not (L.null  versions ) then  return(s,True )
     else if recover== True then return(s{recover=False}, False)
     else return (s,False))

-- | For debugging purposes.
-- At recovery time, instead of returning the stored value from the log
-- , stepDebug executes the computation 'f' as normally.
-- . It permits the exact re-execution of a workflow process
stepDebug :: ( Monad m
        , MonadIO m
        , Serialize a
        , Typeable a)
        =>  m a
        ->  Workflow m a
stepDebug  f = r
 where
 r= do
    WF(\s ->
        let stat= state s


        in case recover s && not(L.null $ versions s) of
            True  ->   f >>= \x -> return (s{versions= L.tail $ versions s},x)
            False -> stepExec  (self s)  f)

 typ :: m a -> a
 typ = undefined






-- | Executes a computation 'f' in a loop while the return valoe meets the condition 'cond' is met.
-- At recovery time, the current state of the loop is restored.
-- The loop restart at the last internal state that  was (saved) before shutdown.
--
-- The use of 'while' permits a faster recovery when the loop has many steps and the log is very long, as is the case in
-- NFlow applications,
--while
--  :: MonadIO m =>
--     (b -> Bool) ->  Workflow m b -> Workflow m b
--while  cond f= do
--   n <- WF $ \s -> return (s,state s - L.length (versions s))
----       do
----        let versionss= versions s
----        if recover s && not (L.null versionss)
----          then  return (s{versions=L.tail versionss }, fromIDyn $ L.head versionss )
----
----          else return(s{recover= False, state=state s + 1
----                           ,versions= (toIDyn $ state s):versionss}
----                           ,state s)
--   while1 n
--   where
--   while1 n =do
--           label n
--           x <- f
--           if cond x
--             then while1 n
--             else return x
--
--data Label= Label Int deriving (Eq,Typeable,Read,Show)
--label n  =  do
--    let !label= Label n
--    r <- isInRecover
--    if r
--      then  WF(\s@Stat{..} ->
--        let !label@(Label n) = fromIDyn $ L.head versions
--            !vers = filterMax  (\d -> Just label /= safeFromIDyn d) versions -- !> (show label)
--        in return (s{versions= L.tail  vers}, fromIDyn . L.head $  vers ))
--      else  do
--        step $ return label
--    where
--    filterMax  f xs=
--           case L.dropWhile  f (L.tail xs) of
--                [] ->  xs
--                [_] ->  xs
--                xs' -> filterMax  f xs'
--



-- | start or continue a workflow  .
--  using `killWF` or `delWF` in case of exception.
--  'WFErrors' and exceptions are returned as @Left err@ (even if they were triggered as exceptions).
-- Other exceptions are returned as @Left (Exception e)@

start
    :: ( CMC.MonadCatchIO m
       , MonadIO m
       , Indexable a
       , Serialize a, Serialize b
       , Typeable a
       , Typeable b)
    => String                        -- ^ name thar identifies the workflow.
    -> (a -> Workflow m b)           -- ^ workflow to execute
    -> a                             -- ^ initial value (ever use the initial value for restarting the workflow)
    -> m  (Either WFErrors b)        -- ^ result of the computation
start namewf f1 v =  do
  ei <- getState  namewf f1 v
  case ei of
      Left error -> return $  Left  error
      Right (name, f, stat) ->
        runWF name (f  v) stat  >>= return  .  Right
    `CMC.catch`
           (\(e :: WFErrors) -> do
                 let name=  keyWF namewf v
                 clearRunningFlag name
                 return $ Left e)
    `CMC.catch`
           (\(e :: CE.SomeException) -> liftIO $ do
                 let name=  keyWF namewf v
                 clearRunningFlag name
                 return . Left $ WFException $ show e )


-- | return conditions from the invocation of start/restart primitives
data WFErrors = NotFound  | AlreadyRunning | Timeout | WFException String deriving (Typeable, Read, Show)

--instance Show WFErrors where
--  show NotFound= "Not Found"
--  show AlreadyRunning= "Already Running"
--  show Timeout= "Timeout"
--  show (Exception e)= "Exception: "++ show e

--instance Serialize WFErrors where
--  showp NotFound=  insertString "NotFound"
--  showp AlreadyRunning= insertString "AlreadyRunning"
--  showp Timeout= insertString "Timeout"
--  showp (Exception e)= insertString "Exception: ">> showp e
--
--  readp= choice[notfound,already,timeout, exc]
--   where
--   notfound= symbol "NotFound" >> return NotFound
--   already= symbol "AlreadyRunning" >> return AlreadyRunning
--   timeout= symbol "Timeout" >> return Timeout
--   exc= symbol "Exception" >> readp >>= \s -> return (Exception s)

instance CE.Exception WFErrors



{-
lookup for any workflow for the entry value v
if namewf is found and is running, return arlready running
    if is not runing, restart it
else  start  anew.
-}


getState  :: (Monad m, MonadIO m, Indexable a, Serialize a, Typeable a)
          => String -> x -> a
          -> m (Either WFErrors (String, x, Stat))
getState  namewf f v= liftIO . atomically $ getStateSTM
 where
 getStateSTM = do
      mrunning <- readDBRef tvRunningWfs
      case mrunning of
       Nothing -> do
               writeDBRef tvRunningWfs  (Running $ fromList [])
               getStateSTM
       Just(Running map) ->  do
         let key= keyWF namewf  v
             dynv=  toIDyn v
             stat1= stat0{wfName= key,versions=[dynv],state=1, self= sref}
             sref= getDBRef $ keyResource stat1
         case M.lookup key map of
           Nothing -> do                        -- no workflow started for this object
             mythread <- unsafeIOToSTM $ myThreadId
             safeIOToSTM $ delResource stat1 >> writeResource stat1
             writeDBRef tvRunningWfs . Running $ M.insert key (namewf,Just mythread) map
             writeDBRef sref stat1
             return $ Right (key, f, stat1)

           Just (wf, started) ->               -- a workflow has been initiated for this object
             if isJust started
                then return $ Left AlreadyRunning                       -- `debug` "already running"
                else  do            -- has been running but not running now
                   mst <- readDBRef sref
                   stat' <- case mst of
                          Nothing -> error $ "getState: Workflow not found: "++ key
                          Just s -> do
                             tnow <- unsafeIOToSTM getTimeSeconds
                             if isJust (timeout s)
                              then if lastActive s+ fromJust(timeout s) > tnow  -- !>("lastActive="++show (lastActive s) ++ "tnow="++show tnow)
                                       then
                                         return s{recover= True,timeout=Nothing}
                                       else
                                         -- has been inactive for too much time, clean it
                                         return stat1
                              else     return s{recover= True}


                   writeDBRef sref stat'
                   mythread <- unsafeIOToSTM  myThreadId
                   writeDBRef tvRunningWfs . Running $ M.insert key (namewf,Just mythread) map

                   return $ Right (key, f, stat')



runWF :: (Monad m,MonadIO m
         , Serialize b, Typeable b)
         =>  String ->  Workflow m b -> Stat  -> m  b
runWF n f s= do
   (s', v')  <-  st f s{versions= L.tail $ versions s} -- !> (show $ versions s)
   liftIO $! clearFromRunningList n
   return  v'
   where

   -- eliminate the thread from the list of running workflows but leave the state
   clearFromRunningList n = atomicallySync $ do
      Just(Running map) <-  readDBRef tvRunningWfs
      writeDBRef tvRunningWfs . Running $ M.delete   n   map -- `debug` "clearFromRunningList"

-- | Start or continue a workflow  from a list of workflows  with exception handling.
--  see 'start' for details about exception and error handling
startWF
    ::  ( CMC.MonadCatchIO m, MonadIO m
        , Serialize a, Serialize b
        , Typeable a
        , Indexable a
        , Typeable b)
    =>  String                       -- ^ Name of workflow in the workflow list
    -> a                             -- ^ Initial value (ever use the initial value even to restart the workflow)
    -> WorkflowList m  a b           -- ^ function to execute
    -> m (Either WFErrors b)         -- ^ Result of the computation
startWF namewf v wfs=
   case Prelude.lookup namewf wfs of
     Nothing -> return $ Left NotFound
     Just f -> start namewf f v



-- | re-start the non finished workflows in the list, for all the initial values that they may have been invoked
restartWorkflows
   :: (Serialize a, Serialize b, Typeable a
   , Indexable b,   Typeable b)
   =>  WorkflowList IO a b      -- the list of workflows that implement the module
   -> IO ()                    -- Only workflows in the IO monad can be restarted with restartWorkflows
restartWorkflows map = do
  mw <- liftIO $ getResource ((Running undefined ) )  -- :: IO (Maybe(Stat a))
  case mw of
    Nothing -> return ()
    Just (Running all) ->  mapM_ start . mapMaybe  filter  . toList  $ all
  where
  filter (a, (b,Nothing)) =  Just  (b, a)
  filter _  =  Nothing

  start (key, kv)= do
      let mf= Prelude.lookup key map
      case mf of
        Nothing -> return ()
        Just  f -> do
          let st0= stat0{wfName = kv}
          mst <- liftIO $ getResource st0
          case mst of
                   Nothing -> error $ "restartWorkflows: workflow not found "++ keyResource st0
                   Just st-> do
                     liftIO  .  forkIO $ runWF key (f (fromIDyn . L.head $ versions st )) st{recover=True} >> return ()
                     return ()
--  ei <- getState  namewf f1 v
--  case ei of
--      Left error -> return $  Left  error
--      Right (name, f, stat) ->


-- | return all the steps of the workflow log. The values are dynamic
--
-- to get all the steps  with result of type Int:
--  @all <- `getAll`
--  let lfacts =  mapMaybe `safeFromIDyn` all :: [Int]@
getAll :: Monad m => Workflow m [IDynamic]
getAll=  WF(\s -> return (s, versions s))

--getStep
--      :: (Serialize a, Typeable a,  Monad m)
--      => Int                                 -- ^ the step number. If negative, count from the current state backwards
--      -> Workflow m a                        -- ^ return the n-tn intermediate step result
--getStep i=  WF(\s -> do
--                let ind= index s
--                    stat= state s
--
--                return (s, if i > 0 && i < stat then fromIDyn $ versions s !! (stat -i-1)
--                           else if i <= 0 && i > -stat then fromIDyn $ versions s !! (stat - ind +i-1)
--                           else error "getStep: wrong index")
--             )

-- | return the list of object keys that are running for a workflow
getWFKeys :: String -> IO [String]
getWFKeys wfname= do
      mwfs <- atomically $ readDBRef tvRunningWfs
      case mwfs of
       Nothing   -> return  []
       Just (Running wfs)   -> return $ Prelude.filter (L.isPrefixOf wfname) $ M.keys wfs

-- | return the current state of the computation, in the IO monad
getWFHistory :: (Indexable a, Serialize a) => String -> a -> IO (Maybe Stat)
getWFHistory wfname x=  getResource stat0{wfName=  keyWF wfname  x}

-- | delete the history of a workflow.
-- Be sure that this WF has finished.

--{-# DEPRECATED delWFHistory, delWFHistory1 "use delWF and delWF1 instead" #-}

delWFHistory name1 x = do
      let name= keyWF name1 x
      delWFHistory1 name

delWFHistory1 name  = do
      let proto= stat0{wfName= name}
--      when (isJust mdir) $
--           moveFile (defPath proto ++ key proto)  (defPath proto ++ fromJust mdir)
      atomically . withSTMResources [] $ const resources{  toDelete= [proto] }


waitWFActive wf= do
      r <- threadWF wf
      case r of        -- wait for change in the wofkflow state
            Just (_, Nothing) -> retry
            _ -> return ()
      where
      threadWF wf= do
               Just(Running map) <-  readDBRef tvRunningWfs
               return $ M.lookup wf map


-- | kill the executing thread if not killed, but not its state.
-- `exec` `start` or `restartWorkflows` will continue the workflow
killThreadWF :: ( Indexable a
                , Serialize a

                , Typeable a
                , MonadIO m)
       => String -> a -> m()
killThreadWF wfname x= do
  let name= keyWF wfname x
  killThreadWF1 name

-- | a version of `KillThreadWF` for workflows started wit no parameter by `exec1`
killThreadWF1 ::  MonadIO m => String -> m()
killThreadWF1 name= killThreadWFm name  >> return ()

killThreadWFm name= do
   (map,f) <- clearRunningFlag name
   case f of
    Just th -> liftIO $ killThread th
    Nothing -> return()
   return map



-- | kill the process (if running) and drop it from the list of
--  restart-able workflows. Its state history remains , so it can be inspected with
--  `getWfHistory` `printWFHistory` and so on
killWF :: (Indexable a,MonadIO m) => String -> a -> m ()
killWF name1 x= do
       let name= keyWF name1 x
       killWF1 name

-- | a version of `KillWF` for workflows started wit no parameter by `exec1`
killWF1 :: MonadIO m => String  -> m ()
killWF1 name = do
       map <- killThreadWFm name
       liftIO . atomically . writeDBRef tvRunningWfs . Running $ M.delete   name   map
       return ()

-- | delete the WF from the running list and delete the workflow state from persistent storage.
--  Use it to perform cleanup if the process has been killed.
delWF :: ( Indexable a
         , MonadIO m
         , Typeable a)
        => String -> a -> m()
delWF name1 x=   do
  let name= keyWF name1 x
  delWF1 name


-- | a version of `delWF` for workflows started wit no parameter by `exec1`
delWF1 :: MonadIO m=> String  -> m()
delWF1 name= liftIO $ do
  mrun <- atomically $ readDBRef tvRunningWfs
  case mrun of
    Nothing -> return()
    Just (Running map) -> do
      atomicallySync . writeDBRef tvRunningWfs . Running $! M.delete   name   map
      delWFHistory1 name




clearRunningFlag name= liftIO $ atomically $ do
  mrun <-  readDBRef tvRunningWfs
  case mrun of
   Nothing -> error $ "clearRunningFLag: non existing workflows" ++ name
   Just(Running map) -> do
   case M.lookup  name map of
    Just(_, Nothing) -> return (map,Nothing)
    Just(v, Just th) -> do
      writeDBRef tvRunningWfs . Running $ M.insert name (v, Nothing) map
      return (map,Just th)
    Nothing  ->
      return (map, Nothing)


-- | Return the reference to the last logged result , usually, the last result stored by `step`.
-- wiorkflow references can be accessed outside of the workflow
-- . They also can be (de)serialized.
--
-- WARNING getWFRef can produce  casting errors  when the type demanded
-- do not match the serialized data. Instead,  `newDBRef` and `stepWFRef` are type safe at runtuime.
--getWFRef ::  ( Monad m,
--               MonadIO m,
--               Serialize a
--             , Typeable a)
--             => Workflow m  (WFRef a)
--getWFRef =ret !> "geWFRef"
--   where
--   ret=   WF (\s -> do
--       let  n= if recover s then state s - (L.length $ versions s)
--                            else (state s -1)
--       let  ref = WFRef n (self s)
--       -- to reify the object being accessed
--       -- if not reified, the serializer will write a null object
--       let versionss= versions s
--       when ( L.null versionss) $  error "getWFRef: empty log, no step to point to"
--       let r= fromIDyn (L.head $ versionss) `asTypeOf` typeofRef ret
--       r `seq` return  (s,ref))
--       where
--       typeofRef :: Workflow m  (WFRef a) -> a
--       typeofRef= undefined -- never will be executed


-- | Log a value and return a reference to it.
--
-- @newWFRef x= `step` $ return x >>= `getWFRef`@
newWFRef :: ( Serialize a
           , Typeable a
           , MonadIO m
           , CMC.MonadCatchIO m)
           => a -> Workflow m  (WFRef a)
newWFRef x= stepWFRef (return  x) >>= return . fst

-- | Execute  an step but return a reference to the result besides the result itself
--
stepWFRef :: ( Serialize a
           , Typeable a
           , MonadIO m)
            => m a -> Workflow m  (WFRef a,a)
stepWFRef exp= do
     r <- step exp  -- !> "stepWFRef"

     WF(\s@Stat{..} -> do


       let  (n,flag)= if recover  then (state  - (L.length  versions) -1  ,False)
                          else (state -1 ,True)
       let  ref = WFRef n self
       let s'= s{references= (n,(toIDyn r,flag)):references }
       liftIO $ atomically $ writeDBRef self s'
       r  `seq` return  (s',(ref,r)) )


-- | Read the content of a Workflow reference. Note that its result is not in the Workflow monad
readWFRef :: (  Serialize a
             ,  Typeable a)
             => WFRef a
             -> STM (Maybe a)
readWFRef (WFRef n ref)= do
   mr <- readDBRef ref
   case mr of
    Nothing -> return Nothing
    Just st ->
      case  L.lookup n $! references st of
        Just (r,_) -> return . Just $ fromIDyn r
        Nothing -> do
          let  n1=  state st - n
          return . Just . fromIDyn $ versions st !! n1

--      flushDBRef ref !> "readWFRef"
--      st <- readDBRef ref `justifyM` (error $ "readWFRef: reference has been deleted from storaga: "++ show ref)

--      let elems= case ms of
--            Just s -> versions s ++  (L.reverse $ L.take (state s' - state s)   (versions s'))
--            Nothing -> L.reverse $ versions s'
--          x    = elems !! n
--      writeDBRef ref s'

--      return . Just $! fromIDyn x


justifyM io y=  io >>= return . fromMaybe y

-- | Writes a new value en in the workflow reference, that is, in the workflow log.
-- Why would you use this?.  Don't do that!. modifiying the content of the workflow log would
-- change the excution flow  when the workflow restarts. This metod is used internally in the package
-- the best way to communicate with a workflow is trough a persistent queue:
--
--  @worflow= exec1 "wf" do
--         r <- `stepWFRef`  expr
--         `push` \"queue\" r
--         back <- `pop` \"queueback\"
--         ...
-- @

writeWFRef :: ( Serialize a
                 , Typeable a)
                 => WFRef a
                 -> a
                 -> STM ()
writeWFRef  r@(WFRef n ref) x= do
  mr <- readDBRef ref
  case mr of
    Nothing -> error $ "writeWFRef: workflow does not exist: " ++ show ref
    Just st@Stat{..}  ->
      writeDBRef ref st{references= add x references} !> ("writeWFREF"++ show r)

  where
  add x xs= (n,(toIDyn x,False)) : L.filter (\(n',_) -> n/=n') xs
--      flushDBRef ref !> "writeWFRef"
--      s <- safeIOToSTM $ readResourceByKey (keyObjDBRef ref) `justifyM` (error $ "writeWFRef: reference has been deleted from storaga: "++ show ref)
--      let elems= versions s ++  (L.reverse $ L.take (state s' - state s)   (versions s'))
--
--          (h,t)= L.splitAt n elems
--          elems'= h ++ (toIDyn x:tail' t)
--
--          tail' []= []
--          tail' t = L.tail t



--      elems `seq` writeDBRef  ref s{ versions= elems'}
--      safeIOToSTM $ delResource s >> writeResource s{ versions= L.map tosave $ L.reverse elems'}
--      writeDBRef ref s'


-- | moves the state of workflow with a seed value to become the state of other seed value
-- This may be of interest when the  entry value
-- changes its key value but  should not initiate a new workflow
-- but continues with the current one

moveState   :: (MonadIO m
             , Indexable a
             , Serialize a
             , Typeable a)
             =>String -> a -> a -> m ()
moveState wf t t'=  liftIO $ do
     atomicallySync $ do
           withSTMResources[stat0{wfName= n}] $ doit n
           mrun <-  readDBRef tvRunningWfs
           case mrun of
                Nothing -> return()
                Just (Running map) -> do
                  let mr= M.lookup n map
                  let th= case mr of Nothing -> Nothing; Just(_,mt)-> mt
                  let map'= M.insert n' (wf,th) $ M.delete n map
                  writeDBRef tvRunningWfs $ Running  map'

     where
     n = keyWF wf t
     n'= keyWF wf t'

     doit n [Just s] = resources{toAdd= [ s{wfName=n',versions = toIDyn t': L.tail( versions s) }]
                                ,toDelete=[s]}

     doit n [Nothing]= error $ "moveState: state not found for: " ++ n



-- | Log a message in the workflow history. I can be printed out with 'printWFhistory'
-- The message is printed in the standard output too
logWF :: MonadIO m => String -> Workflow m  ()
logWF str=do
           str <- step . liftIO $ do
            time <-  getClockTime >>=  toCalendarTime >>= return . calendarTimeToString
            Prelude.putStrLn str
            return $ time ++ ": "++ str
           WF $ \s ->  str  `seq` return (s, ())



--------- event handling--------------


-- | Wait until a TCache object (with a certaing key) meet a certain condition (useful to check external actions )
-- NOTE if anoter process delete the object from te cache, then waitForData will no longuer work
-- inside the wokflow, it can be used by lifting it :
--          do
--                x <- step $ ..
--                y <- step $ waitForData ...
--                   ..

waitForData :: (IResource a,  Typeable a)
              => (a -> Bool)                   -- ^ The condition that the retrieved object must meet
            -> a                             -- ^ a partially defined object for which keyResource can be extracted
            -> IO a                          -- ^ return the retrieved object that meet the condition and has the given kwaitForData  filter x=  atomically $ waitForDataSTM  filter x
waitForData f x = atomically $ waitForDataSTM f x

waitForDataSTM ::  (IResource a,  Typeable a)
                  =>  (a -> Bool)               -- ^ The condition that the retrieved object must meet
                -> a                         -- ^ a partially defined object for which keyResource can be extracted
                -> STM a                     -- ^ return the retrieved object that meet the condition and has the given key
waitForDataSTM  filter x=  do
        tv <- newDBRef  x
        do
                mx  <-  readDBRef tv >>= \v -> return $ cast v
                case mx of
                  Nothing -> retry
                  Just x ->
                    case filter x of
                        False -> retry
                        True  -> return x

-- | observe the workflow log untiil a condition is met.
waitFor
      ::   ( Indexable a, Serialize a, Serialize b,  Typeable a
           , Indexable b,  Typeable b)
      =>  (b -> Bool)                    -- ^ The condition that the retrieved object must meet
      -> String                           -- ^ The workflow name
      -> a                                   -- ^  the INITIAL value used in the workflow to start it
      -> IO b                              -- ^  The first event that meet the condition
waitFor  filter wfname x=  atomically $ waitForSTM  filter wfname x

waitForSTM
      ::   ( Indexable a, Serialize a, Serialize b,  Typeable a
           , Indexable b,  Typeable b)
      =>  (b -> Bool)                    -- ^ The condition that the retrieved object must meet
      -> String                          -- ^ The workflow name
      -> a                               -- ^ The INITIAL value used in the workflow to start it
      -> STM b                           -- ^ The first event that meet the condition
waitForSTM  filter wfname x=  do
    let name= keyWF wfname x
    let tv=  getDBRef . keyResource $ stat0{wfName= name}       -- `debug` "**waitFor***"

    mmx  <-  readDBRef tv
    case mmx of
     Nothing -> error ("waitForSTM: Workflow does not exist: "++ name)
     Just mx -> do
        let  Stat{ versions= d:_}=  mx
        case safeFromIDyn d of
          Nothing -> retry                                            -- `debug` "waithFor retry Nothing"
          Just x ->
            case filter x  of
                False -> retry                                          -- `debug` "waitFor false filter retry"
                True  ->  return x      --  `debug` "waitfor return"



--{-# DEPRECATED waitUntilSTM, getTimeoutFlag "use withTimeout instead" #-}

-- | Start the timeout and return the flag to be monitored by 'waitUntilSTM'
-- This timeout is persistent. This means that the time start to count from the first call to getTimeoutFlag on
-- no matter if the workflow is restarted. The time that the worlkflow has been stopped count also.
-- the wait time can exceed the time between failures.
-- when timeout is 0 means no timeout.
getTimeoutFlag
        :: MonadIO m
        => Integer                --  ^ wait time in secods. This timing start from the first time that the timeout was started on. Sucessive restarts of the workflow will respect this timing
       ->  Workflow m (TVar Bool) --  ^ the returned flag in the workflow monad
getTimeoutFlag  0 = WF $ \s ->  liftIO $ newTVarIO False >>= \tv -> return (s, tv)
getTimeoutFlag  t = do
     tnow <- step $ liftIO getTimeSeconds
     flag tnow t
     where
     flag tnow delta = WF $ \s -> do
          tv <- liftIO $ newTVarIO False

          liftIO  $ do
             let t  =  tnow +  delta
             atomically $ writeTVar tv False
             forkIO $  do waitUntil t ;  atomically $ writeTVar tv True
          return (s, tv)

getTimeSeconds :: IO Integer
getTimeSeconds=  do
      TOD n _  <-  getClockTime
      return n

{- | Wait until a certain clock time has passed by monitoring its flag,  in the STM monad.
   This permits to compose timeouts with locks waiting for data using `orElse`

   *example: wait for any respoinse from a Queue  if no response is given in 5 minutes, it is returned True.

  @
   flag <- 'getTimeoutFlag' $  5 * 60
   ap <- 'step'  .  atomically $  readSomewhere >>= return . Just  `orElse`  'waitUntilSTM' flag  >> return Nothing
   case ap of
        Nothing -> do 'logWF' "timeout" ...
        Just x -> do 'logWF' $ "received" ++ show x ...
  @
-}
waitUntilSTM ::  TVar Bool  -> STM()
waitUntilSTM tv = do
        b <- readTVar tv
        if b == False then retry else return ()

-- | Wait until a certain clock time has passed by monitoring its flag,  in the IO monad.
-- See `waitUntilSTM`

waitUntil:: Integer -> IO()
waitUntil t= getTimeSeconds >>= \tnow -> wait (t-tnow)


wait :: Integer -> IO()
wait delta=  do
        let delay | delta < 0= 0
                  | delta > (fromIntegral  maxInt) = maxInt
                  | otherwise  = fromIntegral $  delta
        threadDelay $ delay  * 1000000
        if delta <= 0 then   return () else wait $  delta - (fromIntegral delay )

-- | return either the result of the STM conputation or Nothing in case of timeout
-- This timeout is persistent. This means that the time start to count from the first call to getTimeoutFlag on
-- no matter if the workflow is restarted. The time that the worlkflow has been stopped count also.
-- Thus, the wait time can exceed the time between failures.
-- when timeout is 0 means no timeout.
withTimeout :: ( MonadIO m, Typeable a, Serialize a)=> Integer -> STM a -> Workflow m (Maybe a)
withTimeout time  f = do
  flag <- getTimeoutFlag time
  step . liftIO . atomically $ (f >>=  return  .  Just )
                               `orElse`
                               (waitUntilSTM flag  >> return  Nothing)


-- | executes a computation in the STM monad. If it is not finished after time `time
-- it kill the process. If the workflow is restarted after time2, the workflow
-- will restart from the beginning. If not, it will restart at the last checkpoint.
withKillTimeout :: MonadIO m => String -> Int -> Integer -> STM a -> m a
withKillTimeout id time time2 f = liftIO $ do

  flag <- transientTimeout time 
  r    <- atomically $ (f >>=  return  .  Just ) 
                       `orElse`
                       (waitUntilSTM flag  >> return  Nothing) 
  case r of 
        Just r  -> return   r
        Nothing -> do
          clearRunningFlag id
          if time2 == 0
               then throw Timeout        -- !> "Timeout"
               else do
                  tnow <- getTimeSeconds
                  withResource stat0{wfName=id} $ \ms -> do
                    case ms of
                      Just s -> s{lastActive= tnow,timeout= Just (time2-fromIntegral time)}
                      Nothing -> error $ "withKillTimeout: Workflow not found: "++ id
                  throw Timeout


transientTimeout 0= atomically $ newTVar False
transientTimeout t= do
    flag <- atomically $ newTVar False
    forkIO $ threadDelay (t * 1000000) >> atomically (writeTVar flag True) 
    return flag