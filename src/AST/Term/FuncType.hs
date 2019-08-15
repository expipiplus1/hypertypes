{-# LANGUAGE UndecidableInstances, TemplateHaskell, FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables, FlexibleContexts #-}

module AST.Term.FuncType
    ( FuncType(..), funcIn, funcOut
    , HasFuncType(..)
    ) where

import           AST
import           AST.Combinator.ANode (ANode)
import           Control.DeepSeq (NFData)
import           Control.Lens (Prism', makeLenses)
import           Control.Lens.Operators
import           Data.Binary (Binary)
import           Data.Constraint
import           GHC.Generics (Generic)
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)
import           Text.Show.Combinators ((@|), showCon)

import           Prelude.Compat

data FuncType typ k = FuncType
    { _funcIn  :: Node k typ
    , _funcOut :: Node k typ
    } deriving Generic

instance KNodes (FuncType t) where
    type NodeTypesOf (FuncType t) = ANode t
    {-# INLINE combineConstraints #-}
    combineConstraints _ _ _ = Dict

makeLenses ''FuncType
makeZipMatch ''FuncType
makeKApplicativeBases ''FuncType
makeKTraversableAndFoldable ''FuncType

instance Pretty (Node k typ) => Pretty (FuncType typ k) where
    pPrintPrec lvl p (FuncType i o) =
        pPrintPrec lvl 11 i <+> Pretty.text "->" <+> pPrintPrec lvl 10 o
        & maybeParens (p > 10)

instance
    RecursiveContext (FuncType typ) constraint =>
    Recursively constraint (FuncType typ) where

    {-# INLINE combineRecursive #-}
    combineRecursive =
        r
        where
            r ::
                forall o.
                Recursively o (FuncType typ) =>
                Dict (Recursively (constraint `And` o) (FuncType typ))
            r = withDict (recursive @o @(FuncType typ)) $
                withDict (combineRecursive @constraint @typ @o) Dict

instance Show (Node k typ) => Show (FuncType typ k) where
    showsPrec p (FuncType i o) = (showCon "FuncType" @| i @| o) p

class HasFuncType typ where
    funcType :: Prism' (Tree typ k) (Tree (FuncType typ) k)

deriving instance Eq  (Node k typ) => Eq  (FuncType typ k)
deriving instance Ord (Node k typ) => Ord (FuncType typ k)
instance Binary (Node k typ) => Binary (FuncType typ k)
instance NFData (Node k typ) => NFData (FuncType typ k)
