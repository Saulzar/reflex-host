{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Reflex.Host.App.Class where

import Data.Dependent.Sum

import Reflex.Class hiding (constant)
import Reflex.Host.Class


import Control.Monad
import Control.Monad.State.Strict
import Data.Semigroup.Applicative
import Data.Semigroup
import Data.Maybe
import Data.Foldable
import Data.IORef

import qualified  Data.DList  as DL
import Data.DList (DList)

import Prelude


type AppInputs t = HostFrame t [DSum (EventTrigger t)]


class (Reflex t) => Switchable t r | r -> t where
   -- | Generalization of switchable reactive types (e.g. Event, Behavior)
   genericSwitch :: MonadHold t m => r -> Event t r -> m r


instance (Switchable t a, Switchable t b) => Switchable t (a, b) where
  {-# INLINEABLE genericSwitch #-}
  genericSwitch (a, b) e = liftM2 (,) (genericSwitch a $ fst <$> e) (genericSwitch b $ snd <$> e)


newtype Behaviors t a = Behaviors { unBehaviors :: DList (Behavior t a) } deriving Monoid
newtype Events t a = Events { unEvents :: DList (Event t a) } deriving Monoid

instance (Monoid a, Reflex t) => Switchable t (Behaviors t a)  where
  {-# INLINEABLE genericSwitch #-}
  genericSwitch bs updated = Behaviors . pure <$> switcher (mergeBehaviors bs) (mergeBehaviors <$> updated)
      
instance (Monoid a, Reflex t) => Switchable t (Events t a) where
  {-# INLINEABLE genericSwitch #-}
  genericSwitch es updated = Events . pure <$> switchPromptly (mergeEvents es) (mergeEvents <$> updated)
  
{-# INLINEABLE mergeEvents #-}
mergeEvents :: (Reflex t, Monoid a) => Events t a -> Event t a
mergeEvents = mergeWith mappend . DL.toList . unEvents

{-# INLINEABLE mergeBehaviors #-}
mergeBehaviors :: (Reflex t, Monoid a) => Behaviors t a -> Behavior t a
mergeBehaviors = mconcat . DL.toList . unBehaviors

  
class (Monad m, Monoid r) => HostWriter r m | m -> r  where  
 
  -- | Writes 'r' to the host, analogous to 'tell' from MonadWriter
  tellHost :: r -> m ()
  
  -- | Collect the result of one writer and return it in another
  collectHost :: m a -> m (a, r)
  

class (HostWriter r (m r), HostWriter s (m s)) => HostMap m s r  where  
  
  -- | Embed one HostWriter in another, a function is used to split the 
  --   result of the inner writer into parts to 'tell' the outer writer
  --   and a part to return.
  mapHost :: (s -> (r, b)) -> m s a -> m r (a, b) 
  
  
appendHost :: HostMap m (r, s) r => m (r, s) a -> m r (a, s)
appendHost = mapHost id

holdHost :: (MonadHold t m, HostWriter r m, Switchable t r) => r -> Event t r -> m ()
holdHost initial updated = tellHost =<< genericSwitch initial updated

holdHostF :: (MonadHold t m,  HostWriter r m, Switchable t r, Foldable f) => f r -> Event t (f r) -> m ()
holdHostF initial updated = tellHost =<< genericSwitch (fold initial) (fold <$> updated)

  
class (Reflex t, MonadFix m, MonadHold t m, MonadHold t (Host t m), MonadFix (Host t m),  
       HostWriter r m, Switchable t r) => MonadAppHost t r m | m -> t r where
  type Host t m :: * -> *
    
  -- | Run a monadic action after each frame in which the event fires, and return the result
  -- in a new event which is fired immediately following the frame in which the original
  -- event fired.
  
  performHost :: Event t (Host t m a) -> m (Event t a)
  
  askRunAppHost :: m (m a -> Host t m (a, r)) 
  
  liftAppHost :: Host t m a -> m a
  
  
class (ReflexHost t, MonadIO m, MonadIO (HostFrame t), MonadFix (HostFrame t), 
       MonadReflexCreateTrigger t m) => HostHasIO t m | m -> t 
  
type HostAction t = HostFrame t (DList (DSum (EventTrigger t)))
type ApHostAction t = Ap (HostFrame t) (DList (DSum (EventTrigger t)))



data HostActions t = HostActions 
  { hostPerform   :: Events t (ApHostAction t) 
  , hostPostBuild :: ApHostAction t
  }  

instance ReflexHost t => Monoid (HostActions t) where
  mempty = HostActions mempty mempty
  mappend (HostActions p t) (HostActions p' t') = HostActions (mappend p p') (mappend t t')
  
  
events :: Event t a -> Events t a
events = Events . pure

behaviors :: Behavior t a -> Behaviors t a
behaviors = Behaviors . pure
  
instance ReflexHost t => Switchable t (HostActions t) where
    genericSwitch (HostActions perform postBuild) updated = do
      updatedPerform <- genericSwitch perform (hostPerform <$> updated)
      return (HostActions (updatedPostBuild `mappend` updatedPerform) postBuild)
      
      where
        updatedPostBuild = events (hostPostBuild <$> updated)
      

{-# INLINEABLE makePerform_ #-}
makePerform_ :: ReflexHost t => Event t (HostFrame t ()) -> HostActions t
makePerform_ e = mempty { hostPerform = events $ Ap . fmap (const mempty) <$> e }

{-# INLINEABLE makePerform #-}
makePerform :: ReflexHost t => Event t (HostFrame t (DList (DSum (EventTrigger t)))) -> HostActions t
makePerform e = mempty { hostPerform = events $ Ap <$> e }

{-# INLINEABLE makePostBuild #-}
makePostBuild :: ReflexHost t => HostFrame t (DList (DSum (EventTrigger t))) -> HostActions t
makePostBuild pb = mempty { hostPostBuild = Ap pb }

{-# INLINEABLE mergeHostActions #-}
mergeHostActions :: (ReflexHost t) => Events t (ApHostAction t) -> Event t (HostAction t)
mergeHostActions e = getApp <$> mergeEvents e


      
-- class (HostHasIO t m) => HasPostFrame t m | m -> t where
--   askPostFrame :: m (AppInputs t -> IO ())
  
class (HostHasIO t m) => HasPostAsync t m | m -> t where
  askPostAsync :: m (AppInputs t -> IO ())
   
  
class HasHostActions t r | r -> t where
  fromActions :: HostActions t -> r
 
instance HasHostActions t (HostActions t) where
  {-# INLINE fromActions #-}
  fromActions = id
  
  
{-# INLINE tellActions #-}
tellActions :: (ReflexHost t, HostWriter r m, HasHostActions t r) => HostActions t -> m ()
tellActions = tellHost . fromActions

{-# INLINE performEvent_ #-}
performEvent_ :: (ReflexHost t, HostWriter r m, HasHostActions t r) =>  Event t (HostFrame t ()) -> m ()
performEvent_  = tellActions . makePerform_

{-# INLINE generatePostBuild #-}
generatePostBuild :: (ReflexHost t, HostWriter r m, HasHostActions t r) => HostFrame t (DList (DSum (EventTrigger t))) -> m ()  
generatePostBuild = tellActions . makePostBuild

{-# INLINE schedulePostBuild #-}
schedulePostBuild :: (ReflexHost t, HostWriter r m, HasHostActions t r) => HostFrame t () -> m ()
schedulePostBuild action = generatePostBuild (action >> pure mempty)

-- | Create a new event and return a function that can be used to construct an event
-- trigger with an associated value. Note that this by itself will not fire the event.
-- To fire the event, you still need to use either 'performPostBuild_' or 'getAsyncFire'
-- which can fire these event triggers with an associated value.
--
-- Note that in some cases (such as when there are no listeners), the returned function
-- does return 'Nothing' instead of an event trigger. This does not mean that it will
-- neccessarily return Nothing on the next call too though.
{-# INLINE newEventWithConstructor #-}
newEventWithConstructor
  :: (MonadReflexCreateTrigger t m, MonadIO m, Monoid (f (DSum (EventTrigger t))), Applicative f) => m (Event t a, a -> IO (f (DSum (EventTrigger t))))
newEventWithConstructor = do
  ref <- liftIO $ newIORef Nothing
  event <- newEventWithTrigger (\h -> writeIORef ref Nothing <$ writeIORef ref (Just h))
  return (event, \a -> foldMap pure . fmap (:=> a) <$> liftIO (readIORef ref))
  
{-# INLINE performEvent #-}
performEvent :: (HostHasIO t m, HostWriter r m, HasHostActions t r) =>  Event t (HostFrame t a) -> m (Event t a)
performEvent e = do 
  (event, construct) <- newEventWithConstructor
  tellActions . makePerform $ (\h -> h >>= liftIO . construct) <$> e
  return event

      
class (HasPostAsync t m, HasHostActions t r, MonadAppHost t r m) => MonadIOHost t r m | m -> t r
  
-- deriving creates an error requiring ImpredicativeTypes
instance (Reflex t, MonadReflexCreateTrigger t m) => MonadReflexCreateTrigger t (StateT s m) where
  newEventWithTrigger initializer = lift $ newEventWithTrigger initializer
  newFanEventWithTrigger initializer = lift $ newFanEventWithTrigger initializer
  
