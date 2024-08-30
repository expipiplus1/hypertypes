{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module TypeLang where

import Algebra.PartialOrd
import Control.Applicative
import Control.Lens (ALens')
import qualified Control.Lens as Lens
import Control.Lens.Operators
import Control.Monad.Reader (MonadReader)
import Control.Monad.ST.Class (MonadST (..))
import Data.STRef
import Data.Set (Set)
import Data.String (IsString)
import Generic.Data
import Generics.Constraints (Constraints, makeDerivings)
import Hyper
import Hyper.Class.Optic
import Hyper.Infer
import Hyper.Syntax
import Hyper.Syntax.NamelessScope
import Hyper.Syntax.Nominal
import Hyper.Syntax.Row
import Hyper.Syntax.Scheme
import Hyper.Unify
import Hyper.Unify.Binding
import Hyper.Unify.QuantifiedVar (HasQuantifiedVar (..))
import Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import Text.PrettyPrint.HughesPJClass (Pretty (..), maybeParens)

import Prelude

newtype Name
    = Name String
    deriving stock (Show)
    deriving newtype (Eq, Ord, IsString)

data Typ h
    = TInt
    | TFun (FuncType Typ h)
    | TRec (h :# Row)
    | TVar Name
    | TNom (NominalInst Name Types h)
    deriving (Generic)

data Row h
    = REmpty
    | RExtend (RowExtend Name Typ Row h)
    | RVar Name
    deriving (Generic)

data RConstraints = RowConstraints
    { _rForbiddenFields :: Set Name
    , _rScope :: ScopeLevel
    }
    deriving stock (Eq, Ord, Show, Generic)
    deriving (Semigroup, Monoid) via Generically RConstraints

data Types h = Types
    { _tTyp :: h :# Typ
    , _tRow :: h :# Row
    }
    deriving (Generic)

data TypeError h
    = TypError (UnifyError Typ h)
    | RowError (UnifyError Row h)
    | QVarNotInScope Name
    deriving (Generic)

data PureInferState = PureInferState
    { _pisBindings :: Types # Binding
    , _pisFreshQVars :: Types # Const Int
    }

Lens.makePrisms ''Typ
Lens.makePrisms ''Row
Lens.makePrisms ''TypeError
Lens.makeLenses ''RConstraints
Lens.makeLenses ''Types
Lens.makeLenses ''PureInferState

makeZipMatch ''Types
makeZipMatch ''Typ
makeZipMatch ''Row
makeHContext ''Typ
makeHContext ''Row
makeHMorph ''Row
makeHTraversableApplyAndBases ''Types
makeHTraversableAndBases ''Typ
makeHTraversableAndBases ''Row

makeDerivings [''Eq, ''Ord, ''Show] [''Typ, ''Row, ''Types, ''TypeError]

makeHasHPlain [''Typ, ''Row]

type instance NomVarTypes Typ = Types

instance HasNominalInst Name Typ where nominalInst = _TNom

instance Pretty Name where
    pPrint (Name x) = Pretty.text x

instance Pretty RConstraints where
    pPrintPrec _ p (RowConstraints f _)
        | f == mempty = Pretty.text "*"
        | otherwise = Pretty.text "∌" <+> pPrint (f ^.. Lens.folded) & maybeParens (p > 10)

instance Constraints (Types h) Pretty => Pretty (Types h) where
    pPrintPrec lvl p (Types typ row) =
        pPrintPrec lvl p typ
            <+> pPrintPrec lvl p row

instance Constraints (TypeError h) Pretty => Pretty (TypeError h) where
    pPrintPrec lvl p (TypError x) = pPrintPrec lvl p x
    pPrintPrec lvl p (RowError x) = pPrintPrec lvl p x
    pPrintPrec _ _ (QVarNotInScope x) =
        Pretty.text "quantified type variable not in scope" <+> pPrint x

instance Constraints (Typ h) Pretty => Pretty (Typ h) where
    pPrintPrec _ _ TInt = Pretty.text "Int"
    pPrintPrec lvl p (TFun x) = pPrintPrec lvl p x
    pPrintPrec lvl p (TRec x) = pPrintPrec lvl p x
    pPrintPrec _ _ (TVar s) = pPrint s
    pPrintPrec _ _ (TNom n) = pPrint n

instance Constraints (Types h) Pretty => Pretty (Row h) where
    pPrintPrec _ _ REmpty = Pretty.text "{}"
    pPrintPrec lvl p (RExtend (RowExtend h v r)) =
        pPrintPrec lvl 20 h
            <+> Pretty.text ":"
            <+> pPrintPrec lvl 2 v
            <+> Pretty.text ":*:"
            <+> pPrintPrec lvl 1 r
            & maybeParens (p > 1)
    pPrintPrec _ _ (RVar s) = pPrint s

instance HNodeLens Types Typ where hNodeLens = tTyp
instance HNodeLens Types Row where hNodeLens = tRow

instance PartialOrd RConstraints where
    RowConstraints f0 s0 `leq` RowConstraints f1 s1 = f0 `leq` f1 && s0 `leq` s1

instance TypeConstraints RConstraints where
    generalizeConstraints = rScope .~ mempty
    toScopeConstraints = rForbiddenFields .~ mempty

instance RowConstraints RConstraints where
    type RowConstraintsKey RConstraints = Name
    forbidden = rForbiddenFields

instance HasTypeConstraints Typ where
    type TypeConstraintsOf Typ = ScopeLevel
    verifyConstraints _ TInt = Just TInt
    verifyConstraints _ (TVar v) = TVar v & Just
    verifyConstraints c (TFun f) = f & hmapped1 %~ WithConstraint c & TFun & Just
    verifyConstraints c (TRec r) = WithConstraint (RowConstraints mempty c) r & TRec & Just
    verifyConstraints c (TNom (NominalInst n (Types t r))) =
        Types
            (t & _QVarInstances . traverse %~ WithConstraint c)
            (r & _QVarInstances . traverse %~ WithConstraint (RowConstraints mempty c))
            & NominalInst n
            & TNom
            & Just

instance HasTypeConstraints Row where
    type TypeConstraintsOf Row = RConstraints
    verifyConstraints _ REmpty = Just REmpty
    verifyConstraints _ (RVar x) = RVar x & Just
    verifyConstraints c (RExtend x) =
        verifyRowExtendConstraints (^. rScope) c x <&> RExtend

emptyPureInferState :: PureInferState
emptyPureInferState =
    PureInferState
        { _pisBindings = Types emptyBinding emptyBinding
        , _pisFreshQVars = Types (Const 0) (Const 0)
        }

type STNameGen s = Types # Const (STRef s Int)

instance (c Typ, c Row) => Recursively c Typ
instance (c Typ, c Row) => Recursively c Row
instance RNodes Typ
instance RNodes Row
instance RTraversable Typ
instance RTraversable Row

instance HasQuantifiedVar Typ where
    type QVar Typ = Name
    quantifiedVar = _TVar

instance HasQuantifiedVar Row where
    type QVar Row = Name
    quantifiedVar = _RVar

instance HSubset Typ Typ (FuncType Typ) (FuncType Typ) where hSubset = _TFun
instance HSubset TypeError TypeError (UnifyError Typ) (UnifyError Typ) where hSubset = _TypError
instance HSubset TypeError TypeError (UnifyError Row) (UnifyError Row) where hSubset = _RowError

instance HasScopeTypes v Typ a => HasScopeTypes v Typ (a, x) where
    scopeTypes = Lens._1 . scopeTypes

type instance InferOf Typ = ANode Typ
type instance InferOf Row = ANode Row
instance HasInferredValue Typ where inferredValue = _ANode
instance HasInferredValue Row where inferredValue = _ANode

instance
    (Monad m, MonadInstantiate m Typ, MonadInstantiate m Row) =>
    Infer m Typ
    where
    inferBody = inferType

instance
    (Monad m, MonadInstantiate m Typ, MonadInstantiate m Row) =>
    Infer m Row
    where
    inferBody = inferType

rStructureMismatch ::
    (UnifyGen m Typ, UnifyGen m Row) =>
    (forall c. Unify m c => UVarOf m # c -> UVarOf m # c -> m (UVarOf m # c)) ->
    Row # UVarOf m ->
    Row # UVarOf m ->
    m ()
rStructureMismatch match (RExtend r0) (RExtend r1) =
    rowExtendStructureMismatch match _RExtend r0 r1
rStructureMismatch _ x y = unifyError (Mismatch x y)

readModifySTRef :: MonadST m => STRef (World m) a -> (a -> a) -> m a
readModifySTRef ref func =
    do
        old <- readSTRef ref
        old <$ (writeSTRef ref $! func old)
        & liftST

newStQuantified ::
    (MonadReader env m, MonadST m, Enum a) =>
    ALens' env (Const (STRef (World m) a) (ast :: AHyperType)) ->
    m a
newStQuantified l =
    Lens.view (Lens.cloneLens l . Lens._Wrapped)
        >>= (`readModifySTRef` succ)
