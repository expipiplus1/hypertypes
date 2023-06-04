{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | A pure data structures implementation of unification variables state
module Hyper.Unify.Binding
    ( UVar (..)
    , _UVar
    , Binding (..)
    , _Binding
    , emptyBinding
    , bindingDict
    ) where

import Control.Lens (ALens')
import qualified Control.Lens as Lens
import Control.Monad.State (MonadState (..))
import Data.Sequence (Seq)
import Hyper.Class.Unify (BindingDict (..))
import Hyper.Type (AHyperType, type (#))
import Hyper.Unify.Term

import Hyper.Internal.Prelude

-- | A unification variable identifier pure state based unification
newtype UVar (t :: AHyperType) = UVar Int
    deriving stock (Generic, Show)
    deriving newtype (Eq, Ord)

makePrisms ''UVar

-- | The state of unification variables implemented in a pure data structure
newtype Binding t = Binding (Seq (UTerm UVar t))
    deriving stock (Generic)

makePrisms ''Binding
makeCommonInstances [''Binding]

-- | An empty 'Binding'
emptyBinding :: Binding t
emptyBinding = Binding mempty

-- | A 'BindingDict' for 'UVar's in a 'MonadState' whose state contains a 'Binding'
{-# INLINE bindingDict #-}
bindingDict ::
    MonadState s m =>
    ALens' s (Binding # t) ->
    BindingDict UVar m t
bindingDict l =
    BindingDict
        { lookupVar =
            \(UVar h) ->
                Lens.use (Lens.cloneLens l . _Binding)
                    <&> (^?! Lens.ix h)
        , newVar =
            \x ->
                Lens.cloneLens l . _Binding <<%= (Lens.|> x)
                    <&> UVar . length
        , bindVar =
            \(UVar h) ->
                (Lens.cloneLens l . _Binding . Lens.ix h .=)
        }
