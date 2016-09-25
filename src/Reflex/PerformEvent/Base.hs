{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Reflex.PerformEvent.Base where

import Reflex.Class
import Reflex.Host.Class
import Reflex.PerformEvent.Class

import Control.Lens
import Control.Monad.Exception
import Control.Monad.Identity
import Control.Monad.Primitive
import Control.Monad.Ref
import Control.Monad.State.Strict
import Control.Monad.Reader
import Data.Coerce
import Data.Dependent.Map (DMap, GCompare (..), Some)
import qualified Data.Dependent.Map as DMap
import Data.Dependent.Sum
import Data.Functor.Compose
import Data.Functor.Misc
import Data.Semigroup
import qualified Data.Some as Some
import Data.These
import Data.Tuple
import Data.Unique.Tag

import Unsafe.Coerce

newtype EventTriggerRef t m a = EventTriggerRef { unEventTriggerRef :: Ref m (Maybe (EventTrigger t a)) }

newtype FireCommand t m = FireCommand { runFireCommand :: forall a. [DSum (EventTrigger t) Identity] -> ReadPhase m a -> m [a] } --TODO: The handling of this ReadPhase seems wrong, or at least inelegant; how do we actually make the decision about what order frames run in?

newtype PerformEventT t m a = PerformEventT { unPerformEventT :: RequestT t (HostFrame t) Identity (HostFrame t) a }

deriving instance ReflexHost t => Functor (PerformEventT t m)
deriving instance ReflexHost t => Applicative (PerformEventT t m)
deriving instance ReflexHost t => Monad (PerformEventT t m)
deriving instance ReflexHost t => MonadFix (PerformEventT t m)
deriving instance (ReflexHost t, MonadIO (HostFrame t)) => MonadIO (PerformEventT t m)
deriving instance (ReflexHost t, MonadException (HostFrame t)) => MonadException (PerformEventT t m)

instance (ReflexHost t, Ref m ~ Ref IO, PrimMonad (HostFrame t)) => PerformEvent t (PerformEventT t m) where
  type Performable (PerformEventT t m) = HostFrame t
  {-# INLINABLE performEvent_ #-}
  performEvent_ = PerformEventT . requesting_
  {-# INLINABLE performEvent #-}
  performEvent = PerformEventT . fmap (fmap runIdentity) . requesting

instance (ReflexHost t, PrimMonad (HostFrame t)) => MonadAdjust t (PerformEventT t m) where
  sequenceDMapWithAdjust outerDm0 outerDm' = PerformEventT $ sequenceDMapWithAdjustRequestTWith f (coerce outerDm0) (unsafeCoerce outerDm') --TODO: Eliminate unsafeCoerce (why doesn't coerce work here, even inside the Event and PatchDMap?)
    where f :: DMap k (HostFrame t) -> Event t (PatchDMap (DMap k (HostFrame t))) -> RequestT t (HostFrame t) Identity (HostFrame t) (DMap k Identity, Event t (PatchDMap (DMap k Identity)))
          f dm0 dm' = do
            result0 <- lift $ DMap.traverseWithKey (\_ v -> Identity <$> v) dm0
            result' <- requesting $ ffor dm' $ \(PatchDMap p) -> do
              PatchDMap <$> DMap.traverseWithKey (\_ (Compose mv) -> Compose <$> mapM (fmap Identity) mv) p
            return (result0, fmap runIdentity result')

instance ReflexHost t => MonadReflexCreateTrigger t (PerformEventT t m) where
  {-# INLINABLE newEventWithTrigger #-}
  newEventWithTrigger = PerformEventT . lift . newEventWithTrigger
  {-# INLINABLE newFanEventWithTrigger #-}
  newFanEventWithTrigger f = PerformEventT $ lift $ newFanEventWithTrigger f

{-# INLINABLE hostPerformEventT #-}
hostPerformEventT :: forall t m a.
                     ( Monad m
                     , MonadSubscribeEvent t m
                     , MonadReflexHost t m
                     , MonadRef m
                     , Ref m ~ Ref IO
                     )
                  => PerformEventT t m a
                  -> m (a, FireCommand t m)
hostPerformEventT a = do
  (response, responseTrigger) <- newEventWithTriggerRef
  (result, eventToPerform) <- runHostFrame $ runRequestT (unPerformEventT a) response
  eventToPerformHandle <- subscribeEvent eventToPerform
  return $ (,) result $ FireCommand $ \triggers (readPhase :: ReadPhase m a') -> do
    let go :: [DSum (EventTrigger t) Identity] -> m [a']
        go ts = do
          (result', mToPerform) <- fireEventsAndRead ts $ do
            mToPerform <- sequence =<< readEvent eventToPerformHandle
            result' <- readPhase
            return (result', mToPerform)
          case mToPerform of
            Nothing -> return [result']
            Just toPerform -> do
              responses <- runHostFrame $ DMap.traverseWithKey (\_ v -> Identity <$> v) toPerform
              mrt <- readRef responseTrigger
              let followupEventTriggers = case mrt of
                    Just rt -> [rt :=> Identity responses]
                    Nothing -> []
              (result':) <$> go followupEventTriggers
    go triggers

instance ReflexHost t => MonadSample t (PerformEventT t m) where
  {-# INLINABLE sample #-}
  sample = PerformEventT . lift . sample

instance (ReflexHost t, MonadHold t m) => MonadHold t (PerformEventT t m) where
  {-# INLINABLE hold #-}
  hold v0 v' = PerformEventT $ lift $ hold v0 v'
  {-# INLINABLE holdDyn #-}
  holdDyn v0 v' = PerformEventT $ lift $ holdDyn v0 v'
  {-# INLINABLE holdIncremental #-}
  holdIncremental v0 v' = PerformEventT $ lift $ holdIncremental v0 v'

instance (MonadRef (HostFrame t), ReflexHost t) => MonadRef (PerformEventT t m) where
  type Ref (PerformEventT t m) = Ref (HostFrame t)
  {-# INLINABLE newRef #-}
  newRef = PerformEventT . lift . newRef
  {-# INLINABLE readRef #-}
  readRef = PerformEventT . lift . readRef
  {-# INLINABLE writeRef #-}
  writeRef r = PerformEventT . lift . writeRef r

instance (MonadAtomicRef (HostFrame t), ReflexHost t) => MonadAtomicRef (PerformEventT t m) where
  {-# INLINABLE atomicModifyRef #-}
  atomicModifyRef r = PerformEventT . lift . atomicModifyRef r

--------------------------------------------------------------------------------
-- RequestT
--------------------------------------------------------------------------------

newtype RequestT t request response m a
  = RequestT { unRequestT :: StateT [Event t (DMap (Tag (PrimState m)) request)] (ReaderT (EventSelector t (WrapArg response (Tag (PrimState m)))) m) a }
  deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadException)

instance MonadTrans (RequestT t request response) where
  lift = RequestT . lift . lift

runRequestT :: forall t m a request response.
               ( Reflex t
               , Monad m
               )
            => RequestT t request response m a
            -> Event t (DMap (Tag (PrimState m)) response)
            -> m (a, Event t (DMap (Tag (PrimState m)) request))
runRequestT (RequestT a) responses = do
  (result, requests) <- runReaderT (runStateT a mempty) $ fan $ mapKeyValuePairsMonotonic (\(t :=> e) -> WrapArg t :=> Identity e) <$> responses
  return (result, mergeWith DMap.union requests)

requesting_ :: (Reflex t, PrimMonad m) => Event t (request a) -> RequestT t request response m ()
requesting_ req = do
  t <- lift newTag
  RequestT $ modify $ (:) $ DMap.singleton t <$> req

withRequesting :: (Reflex t, PrimMonad m) => (Event t (response a) -> RequestT t request response m (Event t (request a), r)) -> RequestT t request response m r
withRequesting a = do
  t <- lift newTag
  s <- RequestT ask
  (req, result) <- a $ select s $ WrapArg t
  RequestT $ modify $ (:) $ DMap.singleton t <$> req
  return result

requesting :: (Reflex t, PrimMonad m) => Event t (request a) -> RequestT t request response m (Event t (response a))
requesting req = withRequesting $ return . (,) req

data DMapTransform (a :: *) k k' v v' = forall (b :: *). DMapTransform !(k a -> k' b) !(v a -> v' b)

mapPatchKeysAndValuesMonotonic :: GCompare k' => (forall a. DMapTransform a k k' v v') -> PatchDMap (DMap k v) -> PatchDMap (DMap k' v')
mapPatchKeysAndValuesMonotonic x (PatchDMap p) = PatchDMap $ mapKeyValuePairsMonotonic (\(k :=> Compose mv) -> case x of DMapTransform f g -> f k :=> Compose (fmap g mv)) p

mapKeysAndValuesMonotonic :: (forall a. DMapTransform a k k' v v') -> DMap k v -> DMap k' v'
mapKeysAndValuesMonotonic x = mapKeyValuePairsMonotonic $ \(k :=> v) -> case x of
  DMapTransform f g -> f k :=> g v

instance MonadSample t m => MonadSample t (RequestT t request response m) where
  sample = lift . sample

instance MonadHold t m => MonadHold t (RequestT t request response m) where
  hold v0 = lift . hold v0
  holdDyn v0 = lift . holdDyn v0
  holdIncremental v0 = lift . holdIncremental v0

instance (Reflex t, MonadAdjust t m, MonadHold t m) => MonadAdjust t (RequestT t request response m) where
  sequenceDMapWithAdjust = sequenceDMapWithAdjustRequestTWith $ \dm0 dm' -> lift $ sequenceDMapWithAdjust dm0 dm'

sequenceDMapWithAdjustRequestTWith :: (GCompare k, Monad m, Reflex t, MonadHold t m)
                                   => (forall k'. GCompare k'
                                       => DMap k' m
                                       -> Event t (PatchDMap (DMap k' m))
                                       -> RequestT t request response m (DMap k' Identity, Event t (PatchDMap (DMap k' Identity)))
                                      )
                                   -> DMap k (RequestT t request response m)
                                   -> Event t (PatchDMap (DMap k (RequestT t request response m)))
                                   -> RequestT t request response m (DMap k Identity, Event t (PatchDMap (DMap k Identity)))
sequenceDMapWithAdjustRequestTWith f (dm0 :: DMap k (RequestT t request response m)) dm' = do
  response <- RequestT ask
  let inputTransform :: forall a. DMapTransform a k (WrapArg ((,) [Event t (DMap (Tag (PrimState m)) request)]) k) (RequestT t request response m) m
      inputTransform = DMapTransform WrapArg (\(RequestT v) -> swap <$> runReaderT (runStateT v mempty) response)
  (children0, children') <- f (mapKeysAndValuesMonotonic inputTransform dm0) $ mapPatchKeysAndValuesMonotonic inputTransform <$> dm'
  let result0 = mapKeyValuePairsMonotonic (\(WrapArg k :=> Identity (_, v)) -> k :=> Identity v) children0
      result' = ffor children' $ \(PatchDMap p) -> PatchDMap $
        mapKeyValuePairsMonotonic (\(WrapArg k :=> Compose mv) -> k :=> Compose (fmap (Identity . snd . runIdentity) mv)) p
      requests0 :: DMap (Const2 (Some k) (DMap (Tag (PrimState m)) request)) (Event t)
      requests0 = mapKeyValuePairsMonotonic (\(WrapArg k :=> Identity (r, _)) -> Const2 (Some.This k) :=> mergeWith DMap.union r) children0
      requests' :: Event t (PatchDMap (DMap (Const2 (Some k) (DMap (Tag (PrimState m)) request)) (Event t)))
      requests' = ffor children' $ \(PatchDMap p) -> PatchDMap $
        mapKeyValuePairsMonotonic (\(WrapArg k :=> Compose mv) -> Const2 (Some.This k) :=> Compose (fmap (mergeWith DMap.union . fst . runIdentity) mv)) p
  childRequestMap <- holdIncremental requests0 requests'
  RequestT $ modify $ (:) $ ffor (mergeIncremental childRequestMap) $ \m ->
    mconcat $ (\(Const2 _ :=> Identity reqs) -> reqs) <$> DMap.toList m
--  RequestT $ modify $ (:) $ coincidence $ ffor requests' $ \(PatchDMap p) -> mergeWith DMap.union $ catMaybes $ ffor (DMap.toList p) $ \(Const2 _ :=> Compose me) -> me -- We could make it prompt like this, but this seems to be slower than just delaying the PostBuild event to allow this stuff to settle (which is more similar to the previous behavior anyway)
  return (result0, result')

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

{-# INLINABLE numberWith #-}
numberWith :: (Enum n, Traversable t) => (n -> a -> b) -> t a -> n -> (t b, n)
numberWith f t n0 = flip runState n0 $ forM t $ \x -> state $ \n -> (f n x, succ n)

{-# INLINABLE mergeSelfDeletingEvents #-}
mergeSelfDeletingEvents :: forall t m k v. (Ord k, Reflex t, MonadFix m, MonadHold t m)
  => DMap (Const2 k (These v ())) (Event t)
  -> Event t (PatchDMap (DMap (Const2 k (These v ())) (Event t)))
  -> m (Event t [v])
mergeSelfDeletingEvents initial eAddNew = do
  rec events :: Incremental t PatchDMap (DMap (Const2 k (These v ())) (Event t))
        <- holdIncremental initial $ eAddNew <> eDelete --TODO: Eliminate empty firings
      let event = mergeWith DMap.union
            [ mergeIncremental events
            , coincidence $ ffor eAddNew $ \(PatchDMap m) -> merge $ DMap.mapMaybeWithKey (const getCompose) m
            ]
          eDelete :: Event t (PatchDMap (DMap (Const2 k (These v ())) (Event t)))
          eDelete = fforMaybe event $
            fmap (PatchDMap . DMap.fromDistinctAscList) .
            (\l -> if null l then Nothing else Just l) .
            fmapMaybe (\(Const2 k :=> Identity x) -> (Const2 k :=> Compose Nothing) <$ x ^? there) .
            DMap.toList
  return $ ffor event $
    fmapMaybe (\(Const2 _ :=> Identity x) -> x ^? here) .
    DMap.toList
