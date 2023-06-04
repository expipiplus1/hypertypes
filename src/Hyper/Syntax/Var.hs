{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Variables.
module Hyper.Syntax.Var
    ( Var (..)
    , _Var
    , VarType (..)
    , ScopeOf
    , HasScope (..)
    ) where

import Hyper
import Hyper.Infer
import Hyper.Unify (UVarOf, UnifyGen)
import Text.PrettyPrint.HughesPJClass (Pretty (..))

import Hyper.Internal.Prelude

type family ScopeOf (t :: HyperType) :: HyperType

class HasScope m s where
    getScope :: m (s # UVarOf m)

class VarType var expr where
    -- | Instantiate a type for a variable in a given scope
    varType ::
        UnifyGen m (TypeOf expr) =>
        Proxy expr ->
        var ->
        ScopeOf expr # UVarOf m ->
        m (UVarOf m # TypeOf expr)

-- | Parameterized by term AST and not by its type AST
-- (which currently is its only part used),
-- for future evaluation/complilation support.
newtype Var v (expr :: HyperType) (h :: AHyperType) = Var v
    deriving newtype (Eq, Ord, Binary, NFData)
    deriving stock (Show, Generic)

makePrisms ''Var
makeHTraversableApplyAndBases ''Var
makeZipMatch ''Var
makeHContext ''Var
makeHMorph ''Var

instance Pretty v => Pretty (Var v expr h) where
    pPrintPrec lvl p (Var v) = pPrintPrec lvl p v

type instance InferOf (Var _ t) = ANode (TypeOf t)

instance HasInferredType (Var v t) where
    type TypeOf (Var v t) = TypeOf t
    {-# INLINE inferredType #-}
    inferredType _ = _ANode

instance
    ( UnifyGen m (TypeOf expr)
    , HasScope m (ScopeOf expr)
    , VarType v expr
    , Monad m
    ) =>
    Infer m (Var v expr)
    where
    {-# INLINE inferBody #-}
    inferBody (Var x) =
        getScope >>= varType (Proxy @expr) x <&> (Var x,) . MkANode
