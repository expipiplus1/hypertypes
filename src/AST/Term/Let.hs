{-# LANGUAGE TemplateHaskell, ScopedTypeVariables, UndecidableInstances, FlexibleInstances #-}

module AST.Term.Let
    ( Let(..), letVar, letEquals, letIn
    ) where

import           AST
import           AST.Class.Unify (Unify, UVarOf)
import           AST.Infer
import           AST.Unify.Generalize (GTerm, generalize)
import           Control.DeepSeq (NFData)
import           Control.Lens (makeLenses)
import           Control.Lens.Operators
import           Data.Binary (Binary)
import           Data.Constraint (Dict(..))
import           Data.Proxy (Proxy(..))
import           Generics.OneLiner (Constraints)
import           GHC.Generics (Generic)
import           Text.PrettyPrint (($+$), (<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

data Let v expr k = Let
    { _letVar :: v
    , _letEquals :: Node k expr
    , _letIn :: Node k expr
    } deriving (Generic)
makeLenses ''Let

instance KNodes (Let v e) where
    type NodesConstraint (Let v e) c = c e
    {-# INLINE kCombineConstraints #-}
    kCombineConstraints _ = Dict

makeKTraversableAndBases ''Let

instance
    Constraints (Let v expr k) Pretty =>
    Pretty (Let v expr k) where
    pPrintPrec lvl p (Let v e i) =
        Pretty.text "let" <+> pPrintPrec lvl 0 v <+> Pretty.text "="
        <+> pPrintPrec lvl 0 e
        $+$ pPrintPrec lvl 0 i
        & maybeParens (p > 0)

instance
    (Inferrable e, KTraversable (InferOf e)) =>
    Inferrable (Let v e) where
    type InferOf (Let v e) = InferOf e

instance
    ( MonadScopeLevel m
    , LocalScopeType v (Tree (GTerm (UVarOf m)) (TypeOf expr)) m
    , Unify m (TypeOf expr)
    , HasInferredType expr
    , NodesConstraint (InferOf expr) (Unify m)
    , KTraversable (InferOf expr)
    , Infer m expr
    ) =>
    Infer m (Let v expr) where

    inferBody (Let v e i) =
        do
            (eI, eG) <-
                do
                    InferredChild eI eR <- inferChild e
                    generalize (eR ^# inferredType (Proxy @expr))
                        <&> (eI ,)
                & localLevel
            inferChild i
                & localScopeType v eG
                <&> \(InferredChild iI iR) -> InferRes (Let v eI iI) iR

deriving instance Constraints (Let v e k) Eq   => Eq   (Let v e k)
deriving instance Constraints (Let v e k) Ord  => Ord  (Let v e k)
deriving instance Constraints (Let v e k) Show => Show (Let v e k)
instance Constraints (Let v e k) Binary => Binary (Let v e k)
instance Constraints (Let v e k) NFData => NFData (Let v e k)
