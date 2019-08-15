{-# LANGUAGE FlexibleInstances, ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances, PolyKinds, TemplateHaskell #-}

module AST.Term.TypeSig
    ( TypeSig(..), tsType, tsTerm
    ) where

import           AST
import           AST.Combinator.Flip (_Flip)
import           AST.Infer
import           AST.Term.Scheme (Scheme)
import           AST.Unify (Unify, unify)
import           AST.Unify.Generalize (instantiateWith)
import           AST.Unify.Term (UTerm(..))
import           Control.DeepSeq (NFData)
import           Control.Lens (makeLenses)
import           Control.Lens.Operators
import           Data.Binary (Binary)
import           Data.Constraint
import           Data.Proxy (Proxy(..))
import           GHC.Generics (Generic)
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

data TypeSig vars term k = TypeSig
    { _tsTerm :: Node k term
    , _tsType :: Node k (Scheme vars (TypeOf term))
    } deriving Generic
makeLenses ''TypeSig

instance KNodes (TypeSig v t) where
    type NodeTypesOf (TypeSig v t) = TypeSig v t
    type NodesConstraint (TypeSig v t) =
        ConcatConstraintFuncs [On t, On (Scheme v (TypeOf t))]
    {-# INLINE combineConstraints #-}
    combineConstraints _ _ _ = Dict

makeKApplicativeBases ''TypeSig
makeKTraversableAndFoldable ''TypeSig

type Deps vars term k cls = ((cls (Node k term), cls (Node k (Scheme vars (TypeOf term)))) :: Constraint)

instance Deps vars term k Pretty => Pretty (TypeSig vars term k) where
    pPrintPrec lvl p (TypeSig term typ) =
        pPrintPrec lvl 1 term <+> Pretty.text ":" <+> pPrintPrec lvl 1 typ
        & maybeParens (p > 1)

type instance InferOf (TypeSig vars term) = InferOf term

instance
    ( MonadScopeLevel m
    , HasInferredType term
    , NodesConstraint vars $ Unify m
    , Recursively KNodes (TypeOf term)
    , Recursively (Unify m) (TypeOf term)
    ) =>
    Infer m (TypeSig vars term) where

    inferBody (TypeSig x s) =
        do
            InferredChild xI xR <- inferChild x
            InferredChild sI sR <- inferChild s
            (t, ()) <- instantiateWith (pure ()) USkolem (sR ^. _Flip)
            xR & inferredType (Proxy @term) #%%~ unify t
                <&> InferRes (TypeSig xI sI)
        & localLevel

deriving instance Deps vars term k Eq   => Eq   (TypeSig vars term k)
deriving instance Deps vars term k Ord  => Ord  (TypeSig vars term k)
deriving instance Deps vars term k Show => Show (TypeSig vars term k)
instance Deps vars term k Binary => Binary (TypeSig vars term k)
instance Deps vars term k NFData => NFData (TypeSig vars term k)
