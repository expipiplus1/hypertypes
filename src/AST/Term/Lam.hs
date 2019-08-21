{-# LANGUAGE TemplateHaskell, ScopedTypeVariables, FlexibleInstances, UndecidableInstances #-}

module AST.Term.Lam
    ( Lam(..), lamIn, lamOut
    ) where

import           AST
import           AST.Infer
import           AST.Term.FuncType
import           AST.Unify (Unify, UVarOf)
import           AST.Unify.New (newUnbound)
import           Control.DeepSeq (NFData)
import           Control.Lens (makeLenses)
import           Control.Lens.Operators
import           Data.Binary (Binary)
import           Data.Constraint (Dict(..))
import           Data.Proxy (Proxy(..))
import           Generics.OneLiner (Constraints)
import           GHC.Generics (Generic)
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint ((<+>))
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

data Lam v expr k = Lam
    { _lamIn :: v
    , _lamOut :: Node k expr
    } deriving Generic
makeLenses ''Lam

instance KNodes (Lam v e) where
    type NodesConstraint (Lam v e) c = c e
    {-# INLINE kCombineConstraints #-}
    kCombineConstraints _ = Dict

makeKTraversableAndBases ''Lam

instance
    Constraints (Lam v expr k) Pretty =>
    Pretty (Lam v expr k) where
    pPrintPrec lvl p (Lam i o) =
        (Pretty.text "λ" <> pPrintPrec lvl 0 i)
        <+> Pretty.text "->" <+> pPrintPrec lvl 0 o
        & maybeParens (p > 0)

instance Inferrable t => Inferrable (Lam v t) where
    type InferOf (Lam v t) = FuncType (TypeOf t)

instance
    ( Infer m t
    , Unify m (TypeOf t)
    , HasInferredType t
    , LocalScopeType v (Tree (UVarOf m) (TypeOf t)) m
    ) =>
    Infer m (Lam v t) where

    {-# INLINE inferBody #-}
    inferBody (Lam p r) =
        do
            varType <- newUnbound
            InferredChild rI rR <- inferChild r & localScopeType p varType
            InferRes (Lam p rI)
                (FuncType varType (rR ^# inferredType (Proxy @t)))
                & pure

deriving instance Constraints (Lam v e k) Eq   => Eq   (Lam v e k)
deriving instance Constraints (Lam v e k) Ord  => Ord  (Lam v e k)
deriving instance Constraints (Lam v e k) Show => Show (Lam v e k)
instance Constraints (Lam v e k) Binary => Binary (Lam v e k)
instance Constraints (Lam v e k) NFData => NFData (Lam v e k)
