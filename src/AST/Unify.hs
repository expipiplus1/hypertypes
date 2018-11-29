{-# LANGUAGE NoImplicitPrelude, DeriveTraversable, TemplateHaskell, MultiParamTypeClasses, FlexibleContexts, LambdaCase, ScopedTypeVariables, UndecidableInstances, UndecidableSuperClasses, TypeFamilies, DefaultSignatures #-}

module AST.Unify
    ( Var, UNode
    , UTerm(..), _UVar, _UTerm
    , unfreeze
    , Binding(..)
    , OccursMonad(..)
    , UnifyMonad(..)
    , applyBindings, unify
    ) where

import           AST (Node, Children(..), overChildren)
import           AST.ZipMatch (ZipMatch(..), zipMatch_)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Except (MonadError(..))
import           Data.Functor.Identity (Identity(..))
import           Data.Proxy (Proxy(..))

import           Prelude.Compat

-- Names modeled after unification-fd

data UTerm f a
    = UVar (f (UTerm f a))
    | UTerm a
Lens.makePrisms ''UTerm

type family Var (m :: * -> *) :: * -> *

type UNode m t = Node (UTerm (Var m)) t
type UVar m t = Var m (UNode m t)

data Binding m t = Binding
    { lookupVar :: UVar m t -> m (Maybe (UNode m t))
    , newVar :: m (UNode m t)
    , bindVar :: UVar m t -> UNode m t -> m ()
    }

class MonadError () m => OccursMonad m where
    type Visited m
    emptyVisited :: Proxy m -> Visited m

    default emptyVisited :: Monoid (Visited m) => Proxy m -> Visited m
    emptyVisited = mempty

class
    ( Eq (UVar m t), ZipMatch t, OccursMonad m
    , ChildrenConstraint t (UnifyMonad m)
    ) => UnifyMonad m t where
    binding :: Binding m t
    visit :: UVar m t -> Visited m -> m (Visited m)

-- | Embed a pure term as a mutable term.
unfreeze :: Children t => Node Identity t -> Node (UTerm v) t
unfreeze (Identity t) = overChildren (Proxy :: Proxy Children) unfreeze t & UTerm

-- look up a variable, and return last variable pointing to result.
-- prune all variable on way to last variable
semiPruneLookup :: forall m t. UnifyMonad m t => UVar m t -> m (UVar m t, Maybe (t (UTerm (Var m))))
semiPruneLookup v0 =
    lookupVar binding v0
    >>=
    \case
    Nothing -> pure (v0, Nothing)
    Just (UTerm t) -> pure (v0, Just t)
    Just (UVar v1) ->
        do
            (v, r) <- semiPruneLookup v1
            bindVar binding v0 (UVar v)
            pure (v, r)

-- TODO: implement when need / better understand motivations for -
-- freeze, fullPrune, occursIn, seenAs, getFreeVars, freshen, equals, equiv

applyBindings :: forall m t. UnifyMonad m t => UNode m t -> m (UNode m t)
applyBindings = applyBindingsH (emptyVisited (Proxy :: Proxy m))

applyBindingsH ::
    forall m t.
    UnifyMonad m t =>
    Visited m -> UNode m t -> m (UNode m t)
applyBindingsH visited (UTerm t) =
    children (Proxy :: Proxy (UnifyMonad m)) (applyBindingsH visited) t <&> UTerm
applyBindingsH visited (UVar v0) =
    semiPruneLookup v0
    >>=
    \case
    (v1, Nothing) -> UVar v1 & pure
    (v1, Just t) ->
        visit v1 visited
        >>= (`applyBindingsH` UTerm t)

-- Note on usage of `semiPruneLookup`:
--   Variables are pruned to point to other variables rather than terms,
--   yielding comparison of (sometimes equal) variables,
--   rather than recursively unifying the terms they would prune to.
unify :: forall m t. UnifyMonad m t => UNode m t -> UNode m t -> m ()
unify (UVar v) (UTerm t) = unifyVarTerm v t
unify (UTerm t) (UVar v) = unifyVarTerm v t
unify (UTerm t0) (UTerm t1) = unifyTerms t0 t1
unify (UVar x0) (UVar y0)
    | x0 == y0 = pure ()
    | otherwise =
        semiPruneLookup x0
        >>=
        \case
        (_, Just x1) -> unifyVarTerm y0 x1
        (x1, Nothing) ->
            semiPruneLookup y0
            >>=
            \case
            (_, Just y1) -> unifyVarTerm x1 y1
            (y1, Nothing) ->
                bindVar binding x1 (UVar y1)

unifyVarTerm :: UnifyMonad m t => UVar m t -> t (UTerm (Var m)) -> m ()
unifyVarTerm x0 y =
    semiPruneLookup x0
    >>=
    \case
    (x1, Nothing) -> bindVar binding x1 (UTerm y)
    (_, Just x1) -> unifyTerms x1 y

unifyTerms ::
    forall m t. UnifyMonad m t =>
    t (UTerm (Var m)) -> t (UTerm (Var m)) -> m ()
unifyTerms =
    zipMatch_ (Proxy :: Proxy (UnifyMonad m)) unify
