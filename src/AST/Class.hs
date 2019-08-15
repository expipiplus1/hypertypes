{-# LANGUAGE RankNTypes, ScopedTypeVariables, FlexibleInstances, UndecidableInstances #-}
{-# LANGUAGE DefaultSignatures, FlexibleContexts #-}

module AST.Class
    ( KNodes(..), NodeTypesConstraints
    , KPointed(..)
    , KFunctor(..), MapK(..), _MapK
    , KApply(..)
    , KApplicative
    , mapK, liftK2
    ) where

import AST.Knot (Knot, Tree)
import Control.Lens (Iso, iso)
import Data.Constraint
import Data.Constraint.List (And)
import Data.Functor.Const (Const(..))
import Data.Functor.Product.PolyKinds (Product(..))
import Data.Kind (Type)
import Data.Proxy (Proxy(..))
import Data.TyFun

import Prelude.Compat

type NodeTypesConstraints k =
    ( NodesConstraint k ~ NodesConstraint (NodeTypesOf k)
    , NodeTypesOf k ~ NodeTypesOf (NodeTypesOf k)
    , KNodes (NodeTypesOf k)
    , KApplicative (NodeTypesOf k)
    )

class KNodes (k :: Knot -> Type) where
    -- | A type family for the different types of children a knot has.
    -- Maps to a simple knot which has a single child of each child type.
    type family NodeTypesOf k :: Knot -> Type

    -- | Lift a constraint to apply to the node types.
    --
    -- Note: It would seem natural to use a simpler type family
    -- which enumerates the nodes types.
    -- It could be then used to lift a constraint to each of them.
    -- But - making such a family is impossible for knots which have
    -- an unbounded set of children types, such as
    -- `Flip GTerm (LangA Nothing)` (with `LangA` from the test suite).
    type family NodesConstraint k :: ((Knot -> Type) -> Constraint) ~> Constraint
    type NodesConstraint k = NodesConstraint (NodeTypesOf k)

    kNodes ::
        Proxy k ->
        Dict (NodeTypesConstraints k)
    {-# INLINE kNodes #-}
    default kNodes ::
        NodeTypesConstraints k =>
        Proxy k ->
        Dict (NodeTypesConstraints k)
    kNodes _ = Dict

    combineConstraints ::
        (NodesConstraint k $ c0, NodesConstraint k $ c1) =>
        Proxy k -> Proxy c0 -> Proxy c1 ->
        Dict (NodesConstraint k $ c0 `And` c1)

class KNodes k => KPointed k where
    -- | Construct a value from a higher ranked child value
    pureK ::
        (forall child. Tree n child) ->
        Tree k n

    -- | Construct a value from a higher ranked child value with a constraint
    pureKWithConstraint ::
        NodesConstraint k $ constraint =>
        Proxy constraint ->
        (forall child. constraint child => Tree n child) ->
        Tree k n

newtype MapK m n (k :: Knot) = MkMapK { runMapK :: m k -> n k }

{-# INLINE _MapK #-}
_MapK ::
    Iso (Tree (MapK m0 n0) k0)
        (Tree (MapK m1 n1) k1)
        (Tree m0 k0 -> Tree n0 k0)
        (Tree m1 k1 -> Tree n1 k1)
_MapK = iso runMapK MkMapK

class KNodes k => KFunctor k where
    -- | Map child values given a mapping function per child type
    mapC ::
        Tree (NodeTypesOf k) (MapK m n) ->
        Tree k m ->
        Tree k n

class KFunctor k => KApply k where
    -- | Combine child values given a combining function per child type
    zipK ::
        Tree k a ->
        Tree k b ->
        Tree k (Product a b)

class    (KPointed k, KApply k) => KApplicative k
instance (KPointed k, KApply k) => KApplicative k

instance KNodes (Const a) where
    type NodeTypesOf (Const a) = Const ()
    type NodesConstraint (Const a) = TConst (() :: Constraint)
    {-# INLINE combineConstraints #-}
    combineConstraints _ _ _ = Dict

instance Monoid a => KPointed (Const a) where
    {-# INLINE pureK #-}
    pureK _ = Const mempty
    {-# INLINE pureKWithConstraint #-}
    pureKWithConstraint _ _ = Const mempty

instance KFunctor (Const a) where
    {-# INLINE mapC #-}
    mapC _ (Const x) = Const x

instance Semigroup a => KApply (Const a) where
    {-# INLINE zipK #-}
    zipK (Const x) (Const y) = Const (x <> y)

instance
    (KNodes a, KNodes b) =>
    KNodes (Product a b) where
    type NodeTypesOf (Product a b) = Product (NodeTypesOf a) (NodeTypesOf b)
    type NodesConstraint (Product a b) = ConcatConstraintFuncs [NodesConstraint a, NodesConstraint b]

    {-# INLINE kNodes #-}
    kNodes _ =
        withDict (kNodes (Proxy @a)) $
        withDict (kNodes (Proxy @b)) Dict

    {-# INLINE combineConstraints #-}
    combineConstraints _ p0 p1 =
        withDict (combineConstraints (Proxy @a) p0 p1) $
        withDict (combineConstraints (Proxy @b) p0 p1) Dict

instance (KPointed a, KPointed b) => KPointed (Product a b) where
    {-# INLINE pureK #-}
    pureK f = Pair (pureK f) (pureK f)
    {-# INLINE pureKWithConstraint #-}
    pureKWithConstraint p f = Pair (pureKWithConstraint p f) (pureKWithConstraint p f)

instance (KFunctor a, KFunctor b) => KFunctor (Product a b) where
    {-# INLINE mapC #-}
    mapC (Pair fx fy) (Pair x y) = Pair (mapC fx x) (mapC fy y)

instance (KApply a, KApply b) => KApply (Product a b) where
    {-# INLINE zipK #-}
    zipK (Pair a0 b0) (Pair a1 b1) = Pair (zipK a0 a1) (zipK b0 b1)

{-# INLINE mapK #-}
mapK ::
    forall k m n.
    KFunctor k =>
    (forall c. Tree m c -> Tree n c) ->
    Tree k m ->
    Tree k n
mapK f x =
    withDict (kNodes (Proxy @k)) $
    mapC (pureK (MkMapK f)) x

{-# INLINE liftK2 #-}
liftK2 ::
    KApply k =>
    (forall c. Tree l c -> Tree m c -> Tree n c) ->
    Tree k l ->
    Tree k m ->
    Tree k n
liftK2 f x = mapK (\(Pair a b) -> f a b) . zipK x
