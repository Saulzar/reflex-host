{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds #-}

module Reflex.Host.App.Class 
  ( IOHost
  , MonadAppHost(..)
  , MonadIOHost(..)
  
  , module Reflex.Host.App.Switching
  
  , MapWriter(..)
  , MonadWriter (..)
  
  ) where


import Data.Dependent.Sum

import Reflex.Class hiding (constant)
import Reflex.Host.Class

import Reflex.Host.App.Switching

import Control.Monad
import Control.Monad.Writer.Class
import Control.Monad.Reader

import Prelude

type IOHost t m = (ReflexHost t, MonadReflexCreateTrigger t m, MonadIO m, MonadIO (HostFrame t))

  
class (MonadWriter r (m r), MonadWriter s (m s)) => MapWriter m s r  where  
  
  -- | Embed one MonadWriter in another, a function is used to split the 
  --   result of the inner writer into parts to 'tell' the outer writer
  --   and a part to return.
  mapWriter :: (s -> (r, b)) -> m s a -> m r (a, b) 
  
  

  
class (ReflexHost t, MonadFix m, MonadHold t m, MonadHold t (Host t m), MonadFix (Host t m),  
       MonadWriter r m, SwitchMerge t r) => MonadAppHost t r m | m -> t r where
  type Host t m :: * -> *
    
  -- | Run a monadic host action during or immediately each frame in which the event fires, 
  -- and return the result in an event fired before other events. 
  -- (Either in the same frame, or in the next immediate frame.
  performEvent :: Event t (Host t m a) -> m (Event t a)
  
  -- | Return a funtion to run a MonadApp action in it's Host 
  -- return it's MonadAppWriter contents.
  askRunApp :: m (m a -> Host t m (a, r)) 
  
  -- | Lift a Host action to a MonadApp action
  liftHost :: Host t m a -> m a
  
  
instance MonadAppHost t r m => MonadAppHost t r (ReaderT e m) where
  
  type Host t (ReaderT e m) = Host t m
  
  performEvent = lift . performEvent
  
  askRunApp = do
    run <- lift askRunApp
    e   <- ask
    return $ run . flip runReaderT e
    
  liftHost = lift . liftHost
  

class (MonadAppHost t r m, MonadIO m, MonadIO (Host t m), 
      MonadReflexCreateTrigger t m) => MonadIOHost t r m | m -> t r  where
        
  -- | Return a function to post events via IO to a fifo Event queue.
  askPostAsync :: m (Host t m [DSum (EventTrigger t)] -> IO ())      

  -- | Run a monadic Host action for the purposes of it's IO effects. 
  -- e.g. for setting properties of an underlying UI or executing an XHR request.
  performEvent_ :: Event t (Host t m ()) -> m ()

  -- | Run host action for it's effects after construction.
  schedulePostBuild_ :: Host t m () -> m ()  
  
  -- | Run host action for it's effects after construction, 
  -- return the result in an Event.
  schedulePostBuild :: Host t m a -> m (Event t a)
  
  

  
