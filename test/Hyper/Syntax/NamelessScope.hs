{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE EmptyDataDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | A 'HyperType' based implementation of "locally-nameless" terms,
-- inspired by the [bound](http://hackage.haskell.org/package/bound) library
-- and the technique from Bird & Paterson's
-- ["de Bruijn notation as a nested datatype"](https://www.semanticscholar.org/paper/De-Bruijn-Notation-as-a-Nested-Datatype-Bird-Paterson/254b3b01651c5e325d9b3cd15c106fbec40e53ea)
module Hyper.Syntax.NamelessScope
    ( Scope (..)
    , _Scope
    , W_Scope (..)
    , ScopeVar (..)
    , _ScopeVar
    , EmptyScope
    , DeBruijnIndex (..)
    , ScopeTypes (..)
    , _ScopeTypes
    , W_ScopeTypes (..)
    , HasScopeTypes (..)
    ) where

import Control.Lens (Lens', Prism')
import qualified Control.Lens as Lens
import Control.Lens.Operators
import Control.Monad.Reader (MonadReader)
import Data.Constraint ((:-), (\\))
import Data.Kind (Type)
import Data.Sequence (Seq)
import qualified Data.Sequence as Sequence
import Hyper
import Hyper.Class.Infer.Infer1
import Hyper.Infer
import Hyper.Syntax.FuncType
import Hyper.Unify (UVarOf, UnifyGen)
import Hyper.Unify.New (newUnbound)

import Prelude

data EmptyScope deriving (Show)

newtype Scope expr a h = Scope (h :# expr (Maybe a))
Lens.makePrisms ''Scope

newtype ScopeVar (expr :: Type -> HyperType) a (h :: AHyperType) = ScopeVar a
Lens.makePrisms ''ScopeVar

makeZipMatch ''Scope
makeHTraversableApplyAndBases ''Scope
makeZipMatch ''ScopeVar
makeHTraversableApplyAndBases ''ScopeVar

class DeBruijnIndex a where
    deBruijnIndex :: Prism' Int a

instance DeBruijnIndex EmptyScope where
    deBruijnIndex = Lens.prism (\case {}) Left

instance DeBruijnIndex a => DeBruijnIndex (Maybe a) where
    deBruijnIndex =
        Lens.prism' toInt fromInt
        where
            toInt Nothing = 0
            toInt (Just x) = 1 + deBruijnIndex # x
            fromInt x
                | x == 0 = Just Nothing
                | otherwise = (x - 1) ^? deBruijnIndex <&> Just

newtype ScopeTypes t v = ScopeTypes (Seq (v :# t))
    deriving newtype (Semigroup, Monoid)

Lens.makePrisms ''ScopeTypes
makeHTraversableApplyAndBases ''ScopeTypes

-- TODO: Replace this class with ones from Infer
class HasScopeTypes v t env where
    scopeTypes :: Lens' env (ScopeTypes t # v)

instance HasScopeTypes v t (ScopeTypes t # v) where
    scopeTypes = id

type instance InferOf (Scope t h) = FuncType (TypeOf (t h))
type instance InferOf (ScopeVar t h) = ANode (TypeOf (t h))

instance HasTypeOf1 t => HasInferOf1 (Scope t) where
    type InferOf1 (Scope t) = FuncType (TypeOf1 t)
    type InferOf1IndexConstraint (Scope t) = DeBruijnIndex
    hasInferOf1 p =
        Dict \\ typeAst (p0 p)
        where
            p0 :: Proxy (Scope t h) -> Proxy (t h)
            p0 _ = Proxy

instance
    ( Infer1 m t
    , InferOf1IndexConstraint t ~ DeBruijnIndex
    , DeBruijnIndex h
    , UnifyGen m (TypeOf (t h))
    , MonadReader env m
    , HasScopeTypes (UVarOf m) (TypeOf (t h)) env
    , HasInferredType (t h)
    ) =>
    Infer m (Scope t h)
    where
    inferBody (Scope x) =
        do
            varType <- newUnbound
            inferChild x
                & Lens.locally (scopeTypes . _ScopeTypes) (varType Sequence.<|)
                <&> \(InferredChild xI xR) ->
                    ( Scope xI
                    , FuncType varType (xR ^# inferredType (Proxy @(t h)))
                    )
            \\ (inferMonad :: DeBruijnIndex (Maybe h) :- Infer m (t (Maybe h)))
            \\ hasInferOf1 (Proxy @(t h))
            \\ hasInferOf1 (Proxy @(t (Maybe h)))

    inferContext _ _ =
        Dict \\ inferMonad @m @t @(Maybe h)

instance
    ( MonadReader env m
    , HasScopeTypes (UVarOf m) (TypeOf (t h)) env
    , DeBruijnIndex h
    , UnifyGen m (TypeOf (t h))
    ) =>
    Infer m (ScopeVar t h)
    where
    inferBody (ScopeVar v) =
        Lens.view (scopeTypes . _ScopeTypes)
            <&> (ScopeVar v,) . MkANode . (^?! Lens.ix (deBruijnIndex # v))
