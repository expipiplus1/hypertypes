{-# LANGUAGE RankNTypes, ScopedTypeVariables, FlexibleContexts #-}

module AST.Class.ZipMatch
    ( ZipMatch(..)
    , zipMatchWith, zipMatchWithA, zipMatchWith_, zipMatch1_
    , doesMatch
    ) where

import           AST.Class
import           AST.Class.Foldable
import           AST.Class.Traversable (KTraversable, traverseKWith)
import           AST.Knot (Tree)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad (guard)
import           Data.Functor.Const (Const(..))
import           Data.Functor.Product.PolyKinds (Product(..))
import           Data.Proxy (Proxy(..))

import           Prelude.Compat

class ZipMatch expr where
    zipMatch :: Tree expr a -> Tree expr b -> Maybe (Tree expr (Product a b))

instance (ZipMatch a, ZipMatch b) => ZipMatch (Product a b) where
    {-# INLINE zipMatch #-}
    zipMatch (Pair a0 b0) (Pair a1 b1) = Pair <$> zipMatch a0 a1 <*> zipMatch b0 b1

instance Eq a => ZipMatch (Const a) where
    {-# INLINE zipMatch #-}
    zipMatch (Const x) (Const y) = Const x <$ guard (x == y)

{-# INLINE zipMatchWithA #-}
zipMatchWithA ::
    forall expr f constraint a b c.
    ( Applicative f
    , ZipMatch expr, KTraversable expr
    , NodesConstraint expr constraint
    ) =>
    Proxy constraint ->
    (forall child. constraint child => Tree a child -> Tree b child -> f (Tree c child)) ->
    Tree expr a -> Tree expr b -> Maybe (f (Tree expr c))
zipMatchWithA p f x y = zipMatch x y <&> traverseKWith p (\(Pair a b) -> f a b)

{-# INLINE zipMatchWith #-}
zipMatchWith ::
    ( ZipMatch expr, KFunctor expr
    , NodesConstraint expr constraint
    ) =>
    Proxy constraint ->
    (forall child. constraint child => Tree a child -> Tree b child -> Tree c child) ->
    Tree expr a -> Tree expr b -> Maybe (Tree expr c)
zipMatchWith p f x y = zipMatch x y <&> mapKWith p (\(Pair a b) -> f a b)

{-# INLINE zipMatchWith_ #-}
zipMatchWith_ ::
    forall f expr constraint a b.
    ( Applicative f
    , ZipMatch expr, KFoldable expr
    , NodesConstraint expr constraint
    ) =>
    Proxy constraint ->
    (forall child. constraint child => Tree a child -> Tree b child -> f ()) ->
    Tree expr a -> Tree expr b -> Maybe (f ())
zipMatchWith_ p f x y = zipMatch x y <&> traverseKWith_ p (\(Pair a b) -> f a b)

{-# INLINE zipMatch1_ #-}
zipMatch1_ ::
    ( Applicative f
    , ZipMatch k, KFoldable k
    , NodesConstraint k ((~) c)
    ) =>
    (Tree a c -> Tree b c -> f ()) ->
    Tree k a -> Tree k b -> Maybe (f ())
zipMatch1_ f x y = zipMatch x y <&> traverseK1_ (\(Pair a b) -> f a b)

{-# INLINE doesMatch #-}
doesMatch :: ZipMatch expr => Tree expr a -> Tree expr b -> Bool
doesMatch x y = Lens.has Lens._Just (zipMatch x y)
