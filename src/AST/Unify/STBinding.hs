{-# LANGUAGE NoImplicitPrelude, TypeFamilies, FlexibleContexts, ScopedTypeVariables #-}

module AST.Unify.STBinding
    ( STVar
    , STBindingState, newSTBindingState
    , stBindingState, stVisit
    , stBindingToInt
    ) where

import           AST (Node, overChildren)
import           AST.Recursive (Recursive(..))
import           AST.Unify (Binding(..), UTerm(..), Var)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Error.Class (MonadError(..))
import           Control.Monad.ST.Class (MonadST(..))
import           Data.Constraint (withDict)
import           Data.Functor.Const (Const(..))
import           Data.IntSet (IntSet)
import           Data.Proxy (Proxy(..))
import           Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)

import           Prelude.Compat

data STVar s a =
    STVar
    { -- For occurs check.
      -- A (more efficient?) alternative would mark the state in the referenced value itself!
      varId :: Int
    , varRef :: STRef s (Maybe (UTerm (STVar s) a))
    }

instance Eq (STVar s a) where
    STVar x _ == STVar y _ = x == y

newtype STBindingState s (t :: (* -> *) -> *) = STBState (STRef s Int)

newSTBindingState :: MonadST m => m (STBindingState (World m) t)
newSTBindingState = newSTRef 0 & liftST <&> STBState

stBindingState ::
    (MonadST m, Var m ~ STVar (World m)) =>
    m (STBindingState (World m) t) ->
    Binding m t
stBindingState getState =
    Binding
    { lookupVar = liftST . readSTRef . varRef
    , newVar =
        do
            STBState nextFreeVarRef <- getState
            do
                nextFreeVar <- readSTRef nextFreeVarRef
                writeSTRef nextFreeVarRef (nextFreeVar + 1)
                newSTRef Nothing <&> STVar nextFreeVar
                & liftST
        <&> UVar
    , bindVar =
        \v t -> writeSTRef (varRef v) (Just t) & liftST
    }

stVisit :: MonadError () m => STVar s a -> IntSet -> m IntSet
stVisit (STVar idx _) =
    Lens.contains idx x
    where
        x True = throwError ()
        x False = pure True

stBindingToInt ::
    forall s t.
    Recursive t =>
    Node (UTerm (STVar s)) t -> Node (UTerm (Const Int)) t
stBindingToInt (UVar v) = UVar (Const (varId v))
stBindingToInt (UTerm t) =
    withDict (recursive (Proxy :: Proxy t))
    (overChildren (Proxy :: Proxy Recursive) stBindingToInt t)
    & UTerm