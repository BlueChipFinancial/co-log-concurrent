{- |
Copyright:  (c) 2018-2020 Kowainik, (c) 2020 Alexander Vershilov
SPDX-License-Identifier: MPL-2.0
Maintainer: Alexander Vershilov <alexander.vershilov@gmail.com>

For the speed reasons, you may want to dump logs asynchronously.
It is especially useful when application threads are CPU
bound while logs emitting is I/O bound. This approach
allows mitigating bottlenecks from the I/O.

When writing an application user should be aware of the tradeoffs
that concurrent log system can provide, in this module, we explain
potential tradeoffs and describe if individual building blocks are
affected or not.

  1. _Unbounded memory usage_ - if there is no backpressure mechanism the user threads,
     threads may generate more logs that can we can store at the same amount of time.
     In such cases messages are accumulated in memory. It extends GC times and memory usage.
  2. _Persistence requirements_ - sometimes application may want to ensure that
     we persisted the logs before it moved to the next statement. It is not a case with
     concurrent log systems in general; some we lose logs even the thread moves forward.
     It may happen when the application exits before dumping all logs.
  3. _Non-precise logging_ - sometimes there may be anomalies when storing logs,
     such as logs reordering or imprecise timestamps.

In case if your application is a subject of those problems you may
consider not using concurrent logging system in other cases concurrent
logging may be a good default for you.
-}

module Colog.Concurrent
       ( -- $general
         -- * Simple API.
         -- $simple-api
         withBackgroundLogger
       , defCapacity
         -- * Extended API
         -- $extended-api
         -- ** Background worker
         -- $background-worker
       , BackgroundWorker
       , backgroundWorkerWrite
       , killBackgroundLogger
         -- ** Background logger
       , forkBackgroundLogger
       , convertToLogAction
         -- ** Worker thread
         -- $worker-thread
       , mkBackgroundThread
       , runInBackgroundThread
         -- *** Usage example
         -- $worker-thread-usage
       ) where

import Control.Applicative (many)
import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Concurrent.STM.TBQueue (newTBQueueIO, readTBQueue, writeTBQueue)
import Control.Exception (bracket, finally)
import Control.Monad (forever, join)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Foldable (for_)

import Colog.Concurrent.Internal (BackgroundWorker (..), Capacity (..))
import Colog.Core.Action (LogAction (..))


{- $general
Concurrent logger consists of the following building blocks (see schema below).

  1. *Logger in the application thread*. The application runs it in the main thread,
      and it has access to all the thread state. This logger can work in any @m@.
  2. *Communication channel with backpressure support*. In addition to the channel,
      we have a converter that puts the user message to the communication channel.
      This converter works in the user thread. Such a logger usually works in 'IO',
      but it's possible to make it work in 'Control.Concurrent.STM.STM' as well.
      At this point, the library provides only 'IO' version, but it can be lifted
      to any 'MonadIO' by the user.
  3. *Logger thread*. It's a background thread that performs an actual synchronous
     write to the log sinks. Loggers there do not have access to the users' thread
     state.

@
   +-------------------------+                  +--------------------------------+
   |                         |                  | Logger        |   Sink-1       |
   |   Application Thread    |                  | Thread    +--->                |
   |   -----------------     |  +-----------+   |           |   +----------------+
   |                         |  |           |   +---------+ |   +----------------+
   |           +-------------+  |  channel  |   | Shared  +----->   Sink-2       |
   |           | application||  |          +----> logger  | |   |                |
   |           | logger    +----->          |   +---------+ |   +----------------+
   |           +-------------+  |           |   |           |   +----------------+
   |                         |  +-----------+   |           +--->   Sink3        |
   |                         |                  |               |                |
   |                         |                  |               +----------------+
   |                         |                  |                                |
   +-------------------------+                  +--------------------------------+
@

So usually user should write the logging system in the way that all 'LogAction.'
that populate and filter information should live in the application logger.
All loggers that do serialization and formatting should live in the shared logger.


If you need more concurrency it's possible to build multilayer systems:

@
  +-------------+                         +-------+
  | application |---+                 +---| sink-1|
  +-------------+   |   +---------+   |   +-------+
                    +---| logger  |---+
                        +---------+   |   +-------+
                                      +---| sink-2|
                                          +-------+
@

In this approach, the application concurrently writes logs to the logger,
then the logger concurrently writing to all sinks.
-}

{- $simple-api
Simple API provides a handy easy to use API that can be used directly
in an application without dealing with internals. Based on users feedback,
the internal implementation of the simple API may change, especially in early
versions of the library. But the guarantee that we give is that no matter
what implementation is, it keeps with reasonable defaults and can be applied
to a generic application.
-}

{- | 
An exception-safe way to create background logger.  This method forks
a thread that runs 'shared worker', see schema above.

@Capacity@ - provides a backpressure mechanism and tells how many messages
in-flight are allowed. In most cases, 'defCapacity' works well.
See 'forkBackgroundLogger' for more details.

@LogAction@ - provides a logger action, this action does not have access to the
application state or thread info, so you should only pass methods that serialize
and dump data there.

@
main :: IO ()
main =
  'withBackgroundLogger'
     'defCapacity'
     'Colog.Actions.logByteStringStdout'
     (\log -> 'Colog.Monad.usingLoggerT' log $ __do__
        'Colog.Monad.logMsg' \@ByteString "Starting application..."
        'Colog.Monad.logMsg' \@ByteString "Finishing application..."
     )
@
-}
withBackgroundLogger
    :: MonadIO m
    => Capacity  -- ^ Capacity of messages to handle; bounded channel size
    -> LogAction IO msg  -- ^ Action that will be used in a forked thread
    -> (LogAction m msg -> IO a)  -- ^ Continuation action
    -> IO a
withBackgroundLogger cap logger action =
   bracket (forkBackgroundLogger cap logger)
           killBackgroundLogger
           (action . convertToLogAction)

-- | Default capacity size, (4096)
defCapacity :: Capacity
defCapacity = Capacity 4096


{- $extended-api

Extended API explains how asynchronous logging is working and provides basic
building blocks for writing your combinators. It is the part of the public API
and does not change without prior notice.
-}

{- $background-worker
The main abstraction for the concurrent worker is 'BackgroundWorker'.
It is a wrapper of the thread, that has a communication channel to talk to and threadId.

Background worker may provide a backpressure mechanism, but does not provide
notification of completeness unless it's included in the message itself.
-}

{- | Stop background logger thread.

The thread is blocked until background thread will finish processing
all messages that were written in the channel.
-}
killBackgroundLogger :: BackgroundWorker msg -> IO ()
killBackgroundLogger bl = do
  killThread (backgroundWorkerThreadId bl)
  atomically $ readTVar (backgroundWorkerIsAlive bl) >>= check . not

{- $background-logger

Background logger is a specialized version of the 'BackgroundWorker' process.
Instead of running any job it accepts @msg@ type
instead and process it with a single logger defined at creation time.
-}

{- | Creates background logger with given @Capacity@,
takes a 'LogAction' that should describe how to write
logs.

@capacity@ - parameter tells how many in-flight messages are allowed,
if that value is reached then user's thread that emits logs is
blocked until any message is written. Usually, if the value is
chosen reasonably high and if this value is reached it means that
the application environment experiences severe problems.

__N.B.__ The 'LogAction' is run in the background
thread so that logger should not add any thread-specific
context to the message.

__N.B.__ On exit, even in case of exception thread will dump all values
that are in the queue. But it will stop doing that in case if another
exception will happen.
-}
forkBackgroundLogger :: Capacity -> LogAction IO msg -> IO (BackgroundWorker msg)
forkBackgroundLogger (Capacity cap) logAction = do
  queue <- newTBQueueIO cap
  isAlive <- newTVarIO True
  tid <- forkFinally
    (forever $ do
      msg <- atomically $ readTBQueue queue
      unLogAction logAction msg)
    (\_ ->
       (do msgs <- atomically $ many $ readTBQueue queue
           for_ msgs $ unLogAction logAction)
         `finally` atomically (writeTVar isAlive False))
  pure $ BackgroundWorker tid (writeTBQueue queue) isAlive


{- | Convert a given 'BackgroundWorker msg' into a 'LogAction msg'
that will send log message to the background thread,
without blocking the thread.

If logger dies for any reason then thread that emits
logs will receive 'BlockedIndefinitelyOnSTM' exception.

You can extend result worker with all functionality available
with co-log. This logger will have an access to the thread
state.
-}
convertToLogAction :: MonadIO m => BackgroundWorker msg -> LogAction m msg
convertToLogAction logger = LogAction $ \msg ->
  liftIO $ atomically $ backgroundWorkerWrite logger msg

{- $worker-thread

While generic background logger is enough for the most
of the usecases, sometimes you may want even more.

There are at least two cases where that may happen:

  1. You need to modify logger, for example different
  threads wants to write to different sources. Or you
  want to change lgo mechanism in runtime.

  2. You may want to implement some notification
  machinery that allows you to guarantee that your
  logs were written before processing further.

In order to solve those problems worker thread abstraction
was introduced. This is a worker that accepts any action
and performs that.
-}

{- | Create a background worker with a given capacity.
If capacity is reached, then the thread that tries to
write logs will be blocked.

This method is more generic than 'forkBackgroundLogger' but
it's less effective, as you have to pass entire closure to
be run and that leads to extra memory usage and indirect calls
happening.

When closed it will dump all pending messages, unless
another asynchronous exception will arrive, or synchronous
exception will happen during the logging.
-}
mkBackgroundThread :: Capacity -> IO (BackgroundWorker (IO ()))
mkBackgroundThread (Capacity cap) = do
  queue <- newTBQueueIO cap
  isAlive <- newTVarIO True
  tid <- forkFinally
    (forever $ join $ atomically $ readTBQueue queue)
    (\_ ->
       (sequence_ =<< atomically (many $ readTBQueue queue))
       `finally` atomically (writeTVar isAlive False))
  pure $ BackgroundWorker tid (writeTBQueue queue) isAlive

{- | Run logger action asynchronously in the worker thread.
Logger is executed in the other thread entirely, so if
logger takes any thread related context it will be
read from the other thread.
-}
runInBackgroundThread :: BackgroundWorker (IO ()) -> LogAction IO msg -> LogAction IO msg
runInBackgroundThread bt logAction = LogAction $ \msg ->
  atomically $ backgroundWorkerWrite bt $ unLogAction logAction msg

{- $worker-thread-usage

Consider following example. (Leaving resource control aside).

@
data M msg = M (MVar ()) msg

notificationLogger :: MonadIO m => LoggerAction m msg -> LoggerAction m (M msg)
notificationLogger logger = 'LogAction' $ \(M lock msg) ->
   (unLogger logger msg) `finally` (putMVar lock ())

example = __do__
   worker <- 'mkBackgroundThread' 'defCapacity'
   lock <- newEmptyMVar
   -- Log message with default logger.
   'unLogger'
      ('runInBackgroundThread' worker
      (notificationLogger $ 'Colog.Action.withLogByteStringFile' "\/var\/log\/myapp\/log")
      (M lock "my message")
   -- Log message with a different logger.
   'unLogger'
      ('runInBackgroundThread' worker
      ('Colog.Action.withLogByteStringFile' "/var/log/myapp/log")
      ("another message")
   -- Block until first message is logged.
   _ <- takeMVar lock
@
-}
