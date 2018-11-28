{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, FlexibleContexts #-}

module AST.Unify.IntBindingState
    ( IntBindingState(..), nextFreeVar, varBindings
    , emptyIntBindingState
    , intBindingState
    , visitSet
    ) where

import           AST (Node)
import           AST.Unify (Binding(..), UTerm(..))
import qualified Control.Lens as Lens
import           Control.Lens (ALens')
import           Control.Lens.Operators
import           Control.Monad.Except (MonadError(..))
import           Control.Monad.State (MonadState(..), modify)
import           Data.IntMap (IntMap)
import           Data.IntSet (IntSet)

import           Prelude.Compat

data IntBindingState t = IntBindingState
    { _nextFreeVar :: {-# UNPACK #-} !Int
    , _varBindings :: IntMap (Node (UTerm Int) t)
    }
Lens.makeLenses ''IntBindingState

emptyIntBindingState :: IntBindingState t
emptyIntBindingState = IntBindingState 0 mempty

intBindingState :: MonadState s m => ALens' s (IntBindingState t) -> Binding Int t m
intBindingState l =
    Binding
    { lookupVar = \k -> Lens.use (Lens.cloneLens l . varBindings . Lens.at k)
    , newVar =
        do
            r <- Lens.use (Lens.cloneLens l . nextFreeVar)
            UVar r <$ modify (Lens.cloneLens l . nextFreeVar +~ 1)
    , bindVar = \k v -> Lens.cloneLens l . varBindings . Lens.at k ?= v
    }

visitSet :: MonadError () m => Int -> IntSet -> m IntSet
visitSet var =
    Lens.contains var x
    where
        x True = throwError ()
        x False = pure True
