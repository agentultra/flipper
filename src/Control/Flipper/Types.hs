{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies      #-}

{-|
Module      : Control.Flipper.Types
Description : Datatype and Typeclass definitions
-}
module Control.Flipper.Types
    ( ActorId(..)
    , Feature(..)
    , Features(..)
    , FeatureName(..)
    , HasActorId(..)
    , HasFeatureFlags(..)
    , ModifiesFeatureFlags(..)
    , Percentage(..)
    , update
    , upsert
    , isEnabledFor
    , mkFeature
    , mkFeatures
    ) where

import           Control.Monad        (void)
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.ByteString (ByteString)
import qualified Data.Digest.CRC32    as D
import qualified Data.List            as L
import           Data.Map.Strict      (Map)
import qualified Data.Map.Strict      as Map
import           Data.Monoid
import           Data.Set             (Set)
import qualified Data.Set             as S
import           Data.String          (IsString (..))
import           Data.Text            (Text)
import qualified Data.Text            as T

{- |
The 'HasFeatureFlags' typeclass describes how to access the Features store
within the current monad.
-}
class Monad m => HasFeatureFlags m where
    -- | 'getFeatures' access the Features store within the current monad
    getFeatures :: m Features

    -- | default implementation provided to reduce boilerplate
    default getFeatures :: (MonadTrans t, HasFeatureFlags m1, m ~ t m1) => m Features
    getFeatures = lift getFeatures

    -- | 'getFeature' access a single Feature within the current monad
    getFeature :: FeatureName -> m (Maybe Feature)

    -- | default implementation provided to reduce boilerplate
    default getFeature :: (MonadTrans t, HasFeatureFlags m1, m ~ t m1) => FeatureName -> m (Maybe Feature)
    getFeature = lift . getFeature

instance (MonadIO m, HasFeatureFlags m) => HasFeatureFlags (StateT s m)
instance (MonadIO m, HasFeatureFlags m) => HasFeatureFlags (ReaderT s m)

{- |
The 'ModifiesFeatureFlags' typeclass describes how to modify the Features store
within the current monad.
-}
class HasFeatureFlags m => ModifiesFeatureFlags m where
    -- | 'updateFeatures' modifies the Features store within the current monad
    updateFeatures :: Features -> m ()

    -- | default implementation provided to reduce boilerplate
    default updateFeatures :: (MonadTrans t, ModifiesFeatureFlags m1, m ~ t m1) => Features -> m ()
    updateFeatures = lift . updateFeatures

    -- | 'updateFeature' modifies a single Feature within the current monad
    updateFeature :: FeatureName -> Feature -> m ()

    -- | default implementation provided to reduce boilerplate
    default updateFeature :: (MonadTrans t, ModifiesFeatureFlags m1, m ~ t m1) => FeatureName -> Feature -> m ()
    updateFeature fName feature = lift $ updateFeature fName feature

instance (MonadIO m, ModifiesFeatureFlags m) => ModifiesFeatureFlags (StateT s m)
instance (MonadIO m, ModifiesFeatureFlags m) => ModifiesFeatureFlags (ReaderT s m)

{- |
A standardization of feature-enableable IDs.
-}
newtype ActorId = ActorId ByteString
    deriving (Show, Eq, Ord, D.CRC32)

{- |
Typeclass describing how to derive an ActorId from a datatype.

The resulting ActorId produced must be unique within the set of actors
permitted to a given feature.

To clarify, let's say the actor is a User and User is defined as
@
data User = User { id :: Int }
@
It's sufficient to use the `id` alone if it is unique among Users and User types
are the only actor type using a given Feature. However, if a Feature is used by
both `User` types and `data Admin = Admin { id :: Int }` types where IDs are _not_
unique between types, it is recommended to avoid collisions by combining the
type name and the ID unique to that type.

For example, the implementation for `User` and Admin could be
@
instance HasActorId User where
    actorId user = "User:" <> show (user id)

instance HasActorId Admin where
    actorId user = "Admin:" <> show (user id)
@
-}
class HasActorId a where
    actorId :: a -> ActorId

{- |
A type describing an access-controlled feature.
-}
data Feature = Feature
    {
    -- | the name of the feature
      featureName     :: FeatureName

    -- | flag indicating if the Feautre is globally enabled
    , isEnabled       :: Bool

    -- | a list of ActorIDs for which to enable the Feature.
    , enabledActors :: Set ActorId

    -- | the percentage of total actors for which to enable the Feature.
    -- | 0 <= enabledPercentage <= 100
    , enabledPercentage :: Percentage
    } deriving (Show, Eq)

{- |
Smart constructor
-}
mkFeature :: FeatureName -> Feature
mkFeature fname = Feature
    { featureName = fname
    , isEnabled = False
    , enabledActors = S.empty
    , enabledPercentage = Percentage 0
    }

newtype Percentage = Percentage Int
    deriving (Show, Read, Eq, Ord, Num)

instance Bounded Percentage where
    minBound = Percentage 0
    maxBound = Percentage 100

{- |
An abstraction representing the current state of the features store.
-}
newtype Features = Features { unFeatures :: Map FeatureName Feature }
    deriving (Show)

instance Monoid Features where
    mempty = Features mempty
    mappend a b = Features (unFeatures a <> unFeatures b)

mkFeatures :: Features
mkFeatures = Features Map.empty

{- |
The main identifier of a feature
-}
newtype FeatureName = FeatureName { unFeatureName :: Text }
    deriving (Show, Eq, Ord)

instance IsString FeatureName where
    fromString s = FeatureName (T.pack s)

upsert :: ModifiesFeatureFlags m
       => Feature -> m ()
upsert f = do
    features <- unFeatures <$> getFeatures
    void . updateFeatures . Features $ Map.insertWith mergeFeatures (featureName f) f  features

mergeFeatures :: Feature -> Feature -> Feature
mergeFeatures new old = Feature
    { featureName = featureName new
    , isEnabled = isEnabled new
    , enabledActors = enabledActors old <> enabledActors new
    , enabledPercentage = enabledPercentage new
    }

{- |
Updates a single Feature within the current monad
-}
update :: ModifiesFeatureFlags m
       => FeatureName -> (Maybe Feature -> Maybe Feature) -> m ()
update fName updateFn = do
    features <- unFeatures <$> getFeatures
    void . updateFeatures . Features $ Map.alter updateFn fName features

isEnabledFor :: (HasActorId a) => Feature -> a -> Bool
isEnabledFor (Feature _ globallyEnabled actors (Percentage pct)) actor =
    globallyEnabled
        || inActivePercentageGroup
        || inActiveActorsGroup
    where
        inActivePercentageGroup = mod (actorHash actor) 100 < pct
        inActiveActorsGroup = actorId actor `L.elem` actors

actorHash :: HasActorId a => a -> Int
actorHash a = fromIntegral . D.crc32 $ actorId a
