{-# LANGUAGE TemplateHaskell, UndecidableInstances, ScopedTypeVariables #-}

module AST.Unify.Error
    ( UnifyError(..)
    , _SkolemUnified, _SkolemEscape, _ConstraintsViolation
    , _Occurs, _Mismatch
    ) where

import           AST
import           AST.Class
import           AST.Unify.Constraints (HasTypeConstraints(..))
import           Control.DeepSeq (NFData)
import           Control.Lens (makePrisms)
import           Data.Binary (Binary)
import           Data.Constraint
import           Data.Proxy
import           GHC.Generics (Generic)
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

-- | An error that occurred during unification
data UnifyError t k
    = SkolemUnified (Node k t) (Node k t)
      -- ^ A universally quantified variable was unified with a
      -- different type
    | SkolemEscape (Node k t)
      -- ^ A universally quantified variable escapes its scope
    | ConstraintsViolation (t k) (TypeConstraintsOf t)
      -- ^ A term violates constraints that should apply to it
    | Occurs (t k) (t k)
      -- ^ Infinite type encountered. A type occurs within itself
    | Mismatch (t k) (t k)
      -- ^ Unification between two mismatching type structures
    deriving Generic
makePrisms ''UnifyError

data UnifyErrorNodes t k = UnifyErrorNodes
    { _ueTerm :: Node k t
    , _ueBody :: NodeTypesOf t k
    }

instance
    KNodes t =>
    KNodes (UnifyErrorNodes t) where

    type NodeTypesOf (UnifyErrorNodes t) = UnifyErrorNodes t
    type NodesConstraint (UnifyErrorNodes t) =
        ConcatConstraintFuncs '[On t, NodesConstraint t]
    {-# INLINE combineConstraints #-}
    combineConstraints _ c0 c1 =
        withDict (combineConstraints (Proxy @t) c0 c1) Dict

instance
    KNodes t =>
    KPointed (UnifyErrorNodes t) where

    {-# INLINE pureK #-}
    pureK f =
        withDict (kNodes (Proxy @t)) $
        UnifyErrorNodes f (pureK f)

    {-# INLINE pureKWithConstraint #-}
    pureKWithConstraint p f =
        withDict (kNodes (Proxy @t)) $
        UnifyErrorNodes f (pureKWithConstraint p f)

instance
    KNodes t =>
    KNodes (UnifyError t) where

    type NodeTypesOf (UnifyError t) = UnifyErrorNodes t
    {-# INLINE combineConstraints #-}
    combineConstraints _ c0 c1 =
        withDict (combineConstraints (Proxy @t) c0 c1) Dict

instance
    KNodes t =>
    KFunctor (UnifyErrorNodes t) where

    {-# INLINE mapC #-}
    mapC (UnifyErrorNodes tf bf) (UnifyErrorNodes tx bx) =
        withDict (kNodes (Proxy @t)) $
        UnifyErrorNodes (runMapK tf tx) (mapC bf bx)

instance
    KNodes t =>
    KApply (UnifyErrorNodes t) where

    {-# INLINE zipK #-}
    zipK (UnifyErrorNodes t0 b0) (UnifyErrorNodes t1 b1) =
        withDict (kNodes (Proxy @t)) $
        UnifyErrorNodes (Pair t0 t1) (zipK b0 b1)

makeKTraversableAndBases ''UnifyError

type Deps c t k = ((c (Node k t), c (t k), c (TypeConstraintsOf t)) :: Constraint)

instance Deps Pretty t k => Pretty (UnifyError t k) where
    pPrintPrec lvl p =
        maybeParens haveParens . \case
        SkolemUnified x y        -> Pretty.text "SkolemUnified" <+> r x <+> r y
        SkolemEscape x           -> Pretty.text "SkolemEscape:" <+> r x
        Mismatch x y             -> Pretty.text "Mismatch" <+> r x <+> r y
        Occurs x y               -> r x <+> Pretty.text "occurs in itself, expands to:" <+> right y
        ConstraintsViolation x y -> Pretty.text "ConstraintsViolation" <+> r x <+> r y
        where
            haveParens = p > 10
            right
                | haveParens = pPrintPrec lvl 0
                | otherwise = pPrintPrec lvl p
            r :: Pretty a => a -> Pretty.Doc
            r = pPrintPrec lvl 11

deriving instance Deps Eq   t k => Eq   (UnifyError t k)
deriving instance Deps Ord  t k => Ord  (UnifyError t k)
deriving instance Deps Show t k => Show (UnifyError t k)
instance Deps Binary t k => Binary (UnifyError t k)
instance Deps NFData t k => NFData (UnifyError t k)
