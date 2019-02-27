{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, TypeFamilies, UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds, StandaloneDeriving, LambdaCase, DeriveGeneric #-}

module AST.Unify.Error
    ( UnifyError(..)
    , _SkolemUnified, _SkolemEscape, _ConstraintsViolation
    , _Occurs, _Mismatch
    ) where

import           AST
import           AST.Unify.Constraints (HasTypeConstraints(..))
import           Control.DeepSeq (NFData)
import           Control.Lens (makePrisms)
import           Data.Binary (Binary)
import           Data.Constraint (Constraint)
import           GHC.Generics (Generic)
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

-- | An error that occurred during unification
data UnifyError t k
    = SkolemUnified (Tie k t) (Tie k t)
      -- ^ A universally quantified variable was unified with a
      -- different type
    | SkolemEscape (Tie k t)
      -- ^ A universally quantified variable escapes its scope
    | ConstraintsViolation (t k) (TypeConstraintsOf t)
      -- ^ A term violates constraints that should apply to it
    | Occurs (t k) (t k)
      -- ^ Infinite type encountered. A type occurs within itself
    | Mismatch (t k) (t k)
      -- ^ Unification between two mismatching type structures
    deriving Generic
makePrisms ''UnifyError
makeChildren ''UnifyError

type Deps c t k = ((c (Tie k t), c (t k), c (TypeConstraintsOf t)) :: Constraint)

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
