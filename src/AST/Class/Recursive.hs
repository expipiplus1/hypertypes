{-# LANGUAGE RankNTypes, DefaultSignatures #-}
{-# OPTIONS -Wno-redundant-constraints #-} -- Work around false GHC warnings

module AST.Class.Recursive
    ( Recursive(..)
    , RNodes(..), RFunctor(..), RFoldable(..), RTraversable(..)
    , RZipMatch(..), RZipMatchTraversable(..)
    , recurseBoth
    , wrap, wrapM, unwrap, unwrapM
    , fold, unfold
    ) where

import AST.Class.Foldable
import AST.Class.Functor (KFunctor(..))
import AST.Class.Nodes (KNodes(..))
import AST.Class.Traversable
import AST.Class.ZipMatch
import AST.Knot
import AST.Knot.Pure (Pure(..), _Pure)
import Control.Lens.Operators
import Data.Constraint.List (NoConstraint, And)
import Data.Functor.Const (Const(..))
import Data.Kind (Constraint, Type)
import Data.Proxy (Proxy(..))

import Prelude.Compat

class Recursive c where
    recurse ::
        (KNodes k, c k) =>
        Proxy (c k) -> (NodesConstraint k c => r) -> r

instance Recursive NoConstraint where
    recurse p = kNoConstraints (argP p)

instance (Recursive a, Recursive b) => Recursive (And a b) where
    recurse p =
        recurse (p0 p) $
        recurse (p1 p) $
        kCombineConstraints p
        where
            p0 :: Proxy (And a b k) -> Proxy (a k)
            p0 _ = Proxy
            p1 :: Proxy (And a b k) -> Proxy (b k)
            p1 _ = Proxy

class KNodes k => RNodes k where
    recursiveKNodes :: Proxy k -> (NodesConstraint k RNodes => r) -> r
    {-# INLINE recursiveKNodes #-}
    default recursiveKNodes ::
        NodesConstraint k RNodes =>
        Proxy k -> (NodesConstraint k RNodes => r) -> r
    recursiveKNodes _ = id

argP :: Proxy (f k :: Constraint) -> Proxy (k :: Knot -> Type)
argP _ = Proxy

instance Recursive RNodes where
    {-# INLINE recurse #-}
    recurse = recursiveKNodes . argP

class (KFunctor k, RNodes k) => RFunctor k where
    recursiveKFunctor :: Proxy k -> (NodesConstraint k RFunctor => r) -> r
    {-# INLINE recursiveKFunctor #-}
    default recursiveKFunctor ::
        NodesConstraint k RFunctor =>
        Proxy k -> (NodesConstraint k RFunctor => r) -> r
    recursiveKFunctor _ = id

instance Recursive RFunctor where
    {-# INLINE recurse #-}
    recurse = recursiveKFunctor . argP

class (KFoldable k, RNodes k) => RFoldable k where
    recursiveKFoldable :: Proxy k -> (NodesConstraint k RFoldable => r) -> r
    {-# INLINE recursiveKFoldable #-}
    default recursiveKFoldable ::
        NodesConstraint k RFoldable =>
        Proxy k -> (NodesConstraint k RFoldable => r) -> r
    recursiveKFoldable _ = id

instance Recursive RFoldable where
    {-# INLINE recurse #-}
    recurse = recursiveKFoldable . argP

class (KTraversable k, RFunctor k, RFoldable k) => RTraversable k where
    recursiveKTraversable :: Proxy k -> (NodesConstraint k RTraversable => r) -> r
    {-# INLINE recursiveKTraversable #-}
    default recursiveKTraversable ::
        NodesConstraint k RTraversable =>
        Proxy k -> (NodesConstraint k RTraversable => r) -> r
    recursiveKTraversable _ = id

instance Recursive RTraversable where
    {-# INLINE recurse #-}
    recurse = recursiveKTraversable . argP

class (ZipMatch k, RNodes k) => RZipMatch k where
    recursiveZipMatch :: Proxy k -> (NodesConstraint k RZipMatch => r) -> r
    {-# INLINE recursiveZipMatch #-}
    default recursiveZipMatch ::
        NodesConstraint k RZipMatch =>
        Proxy k -> (NodesConstraint k RZipMatch => r) -> r
    recursiveZipMatch _ = id

instance Recursive RZipMatch where
    {-# INLINE recurse #-}
    recurse = recursiveZipMatch . argP

class (RTraversable k, RZipMatch k) => RZipMatchTraversable k where
    recursiveZipMatchTraversable ::
        Proxy k -> (NodesConstraint k RZipMatchTraversable => r) -> r
    {-# INLINE recursiveZipMatchTraversable #-}
    default recursiveZipMatchTraversable ::
        NodesConstraint k RZipMatchTraversable =>
        Proxy k -> (NodesConstraint k RZipMatchTraversable => r) -> r
    recursiveZipMatchTraversable _ = id

instance Recursive RZipMatchTraversable where
    {-# INLINE recurse #-}
    recurse = recursiveZipMatchTraversable . argP

{-# INLINE recurseBoth #-}
recurseBoth ::
    forall a b k r.
    (KNodes k, Recursive a, Recursive b, a k, b k) =>
    Proxy (And a b k) -> (NodesConstraint k (And a b) => r) -> r
recurseBoth _ x =
    recurse (Proxy @(a k)) $
    recurse (Proxy @(b k)) $
    kCombineConstraints (Proxy @(And a b k)) x

{-# INLINE wrapM #-}
wrapM ::
    forall m k c w.
    (Monad m, Recursive c, RTraversable k, c k) =>
    Proxy c ->
    (forall n. c n => Tree n w -> m (Tree w n)) ->
    Tree Pure k ->
    m (Tree w k)
wrapM p f x =
    recurseBoth (Proxy @(And RTraversable c k)) $
    x ^. _Pure
    & traverseKWith (Proxy @(And RTraversable c)) (wrapM p f)
    >>= f

{-# INLINE unwrapM #-}
unwrapM ::
    forall m k c w.
    (Monad m, Recursive c, RTraversable k, c k) =>
    Proxy c ->
    (forall n. c n => Tree w n -> m (Tree n w)) ->
    Tree w k ->
    m (Tree Pure k)
unwrapM p f x =
    recurseBoth (Proxy @(And RTraversable c k)) $
    f x
    >>= traverseKWith (Proxy @(And RTraversable c)) (unwrapM p f)
    <&> (_Pure #)

{-# INLINE wrap #-}
wrap ::
    forall k c w.
    (Recursive c, RFunctor k, c k) =>
    Proxy c ->
    (forall n. c n => Tree n w -> Tree w n) ->
    Tree Pure k ->
    Tree w k
wrap p f x =
    recurseBoth (Proxy @(And RFunctor c k)) $
    x ^. _Pure
    & mapKWith (Proxy @(And RFunctor c)) (wrap p f)
    & f

{-# INLINE unwrap #-}
unwrap ::
    forall k c w.
    (Recursive c, RFunctor k, c k) =>
    Proxy c ->
    (forall n. c n => Tree w n -> Tree n w) ->
    Tree w k ->
    Tree Pure k
unwrap p f x =
    recurseBoth (Proxy @(And RFunctor c k)) $
    f x
    & mapKWith (Proxy @(And RFunctor c)) (unwrap p f)
    & MkPure

-- | Recursively fold up a tree to produce a result.
-- TODO: Is this a "cata-morphism"?
{-# INLINE fold #-}
fold ::
    (Recursive c, RFunctor k, c k) =>
    Proxy c ->
    (forall n. c n => Tree n (Const a) -> a) ->
    Tree Pure k ->
    a
fold p f = getConst . wrap p (Const . f)

-- | Build/load a tree from a seed value.
-- TODO: Is this an "ana-morphism"?
{-# INLINE unfold #-}
unfold ::
    (Recursive c, RFunctor k, c k) =>
    Proxy c ->
    (forall n. c n => a -> Tree n (Const a)) ->
    a ->
    Tree Pure k
unfold p f = unwrap p (f . getConst) . Const
