{-# LANGUAGE NoImplicitPrelude, RankNTypes, DefaultSignatures #-}
{-# LANGUAGE MultiParamTypeClasses, ConstraintKinds, FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts, ScopedTypeVariables, UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses, AllowAmbiguousTypes #-}

module AST.Class.Recursive
    ( Recursive(..), RecursiveConstraint
    , wrap, unwrap, wrapM, unwrapM, fold, unfold
    , foldMapRecursive
    ) where

import AST.Class.Children (Children(..), foldMapChildren)
import AST.Knot (Tree)
import AST.Knot.Pure (Pure(..))
import Control.Lens.Operators
import Data.Functor.Const (Const(..))
import Data.Functor.Identity (Identity(..))
import Data.Proxy (Proxy(..))

import Prelude.Compat

-- | `Recursive` carries a constraint to all of the descendant types
-- of an AST. As opposed to the `ChildrenConstraint` type family which
-- only carries a constraint to the direct children of an AST.
class (Children expr, constraint expr) => Recursive constraint expr where
    recursive ::
        Proxy (constraint expr) ->
        (RecursiveConstraint expr constraint => a) ->
        a
    {-# INLINE recursive #-}
    -- | When an instance's constraints already imply
    -- `RecursiveConstraint expr constraint`, the default
    -- implementation can be used.
    default recursive ::
        RecursiveConstraint expr constraint =>
        Proxy (constraint expr) ->
        (RecursiveConstraint expr constraint => a) ->
        a
    recursive _ = id

type RecursiveConstraint expr constraint =
    ( constraint expr
    , ChildrenConstraint expr (Recursive constraint)
    )

instance constraint Pure => Recursive constraint Pure
instance constraint (Const a) => Recursive constraint (Const a)

{-# INLINE wrapM #-}
wrapM ::
    forall constraint expr f m.
    (Monad m, Recursive constraint expr) =>
    Proxy constraint ->
    (forall child. constraint child => Tree child f -> m (Tree f child)) ->
    Tree Pure expr ->
    m (Tree f expr)
wrapM p f (Pure x) =
    recursive (Proxy :: Proxy (constraint expr)) $
    children (Proxy :: Proxy (Recursive constraint)) (wrapM p f) x >>= f

{-# INLINE unwrapM #-}
unwrapM ::
    forall constraint expr f m.
    (Monad m, Recursive constraint expr) =>
    Proxy constraint ->
    (forall child. constraint child => Tree f child -> m (Tree child f)) ->
    Tree f expr ->
    m (Tree Pure expr)
unwrapM p f x =
    recursive (Proxy :: Proxy (constraint expr)) $
    f x >>= children (Proxy :: Proxy (Recursive constraint)) (unwrapM p f) <&> Pure

{-# INLINE wrap #-}
wrap ::
    Recursive constraint expr =>
    Proxy constraint ->
    (forall child. constraint child => Tree child f -> Tree f child) ->
    Tree Pure expr ->
    Tree f expr
wrap p f = runIdentity . wrapM p (Identity . f)

{-# INLINE unwrap #-}
unwrap ::
    Recursive constraint expr =>
    Proxy constraint ->
    (forall child. constraint child => Tree f child -> Tree child f) ->
    Tree f expr ->
    Tree Pure expr
unwrap p f = runIdentity . unwrapM p (Identity . f)

-- | Recursively fold up a tree to produce a result.
-- TODO: Is this a "cata-morphism"?
{-# INLINE fold #-}
fold ::
    Recursive constraint expr =>
    Proxy constraint ->
    (forall child. constraint child => Tree child (Const a) -> a) ->
    Tree Pure expr ->
    a
fold p f = getConst . wrap p (Const . f)

-- | Build/load a tree from a seed value.
-- TODO: Is this an "ana-morphism"?
{-# INLINE unfold #-}
unfold ::
    Recursive constraint expr =>
    Proxy constraint ->
    (forall child. constraint child => a -> Tree child (Const a)) ->
    a ->
    Tree Pure expr
unfold p f = unwrap p (f . getConst) . Const

{-# INLINE foldMapRecursive #-}
foldMapRecursive ::
    forall constraint expr a f.
    (Recursive constraint expr, Recursive Children f, Monoid a) =>
    Proxy constraint ->
    (forall child g. (constraint child, Recursive Children g) => Tree child g -> a) ->
    Tree expr f ->
    a
foldMapRecursive p f x =
    recursive (Proxy :: Proxy (constraint expr)) $
    recursive (Proxy :: Proxy (Children f)) $
    f x <>
    foldMapChildren (Proxy :: Proxy (Recursive constraint))
    (foldMapChildren (Proxy :: Proxy (Recursive Children)) (foldMapRecursive p f))
    x
