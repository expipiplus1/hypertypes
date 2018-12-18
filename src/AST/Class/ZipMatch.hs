{-# LANGUAGE NoImplicitPrelude, RankNTypes, ConstraintKinds, ScopedTypeVariables, DataKinds, KindSignatures, TemplateHaskell #-}

module AST.Class.ZipMatch
    ( ZipMatch(..), Both(..), bothA, bothB
    , zipMatchWith, zipMatchWithA, zipMatchWith_
    , doesMatch
    ) where

import           AST.Class.Children (Children(..))
import           AST.Knot (Knot, Tree)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Data.Functor.Const (Const(..))
import           Data.Functor.Identity (Identity(..))
import           Data.Proxy (Proxy(..))

import           Prelude.Compat

data Both a b (k :: Knot) = Both
    { _bothA :: a k
    , _bothB :: b k
    } deriving (Eq, Ord, Show)
Lens.makeLenses ''Both

class Children expr => ZipMatch expr where
    zipMatch :: Tree expr a -> Tree expr b -> Maybe (Tree expr (Both a b))

zipMatchWithA ::
    (ZipMatch expr, Applicative f, ChildrenConstraint expr constraint) =>
    Proxy constraint ->
    (forall child. constraint child => Tree a child -> Tree b child -> f (Tree c child)) ->
    Tree expr a -> Tree expr b -> Maybe (f (Tree expr c))
zipMatchWithA p f x y =
    zipMatch x y <&> children p g
    where
        g (Both a b) = f a b

zipMatchWith ::
    (ZipMatch expr, ChildrenConstraint expr constraint) =>
    Proxy constraint ->
    (forall child. constraint child => Tree a child -> Tree b child -> Tree c child) ->
    Tree expr a -> Tree expr b -> Maybe (Tree expr c)
zipMatchWith p f x y = zipMatchWithA p (fmap Identity . f) x y <&> runIdentity

zipMatchWith_ ::
    forall f expr constraint a b.
    (Applicative f, ZipMatch expr, ChildrenConstraint expr constraint) =>
    Proxy constraint ->
    (forall child. constraint child => Tree a child -> Tree b child -> f ()) ->
    Tree expr a -> Tree expr b -> Maybe (f ())
zipMatchWith_ p f x y =
    ( zipMatchWithA p (f <&> Lens.mapped . Lens.mapped .~ Const ()) x y
        :: Maybe (f (Tree expr (Const ())))
    ) <&> Lens.mapped .~ ()

doesMatch :: ZipMatch expr => Tree expr a -> Tree expr b -> Bool
doesMatch x y = Lens.has Lens._Just (zipMatch x y)