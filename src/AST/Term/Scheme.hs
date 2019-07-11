{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, TypeFamilies, DataKinds #-}
{-# LANGUAGE ScopedTypeVariables, FlexibleInstances, UndecidableInstances #-}
{-# LANGUAGE DeriveGeneric, StandaloneDeriving, FlexibleContexts, LambdaCase #-}
{-# LANGUAGE ConstraintKinds, TypeOperators, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses, DerivingStrategies #-}

module AST.Term.Scheme
    ( Scheme(..), sForAlls, sTyp
    , QVars(..), _QVars
    , schemeToRestrictedType
    , loadScheme, saveScheme

    , QVarInstances(..), _QVarInstances
    , makeQVarInstances
    ) where

import           AST
import           AST.Class.Combinators (And, NoConstraint, HasChildrenConstraint, proxyNoConstraint)
import           AST.Class.FromChildren (FromChildren(..))
import           AST.Class.HasChild (HasChild(..))
import           AST.Class.Recursive (wrapM, unwrapM)
import           AST.Unify
import           AST.Unify.Lookup (semiPruneLookup)
import           AST.Unify.New (newTerm)
import           AST.Unify.Generalize (GTerm(..), _GMono)
import           AST.Unify.QuantifiedVar (HasQuantifiedVar(..), MonadQuantify(..), QVarHasInstance)
import           AST.Unify.Term (UTerm(..), uBody)
import           Control.DeepSeq (NFData)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.State (StateT(..))
import           Data.Binary (Binary)
import           Data.Constraint (Constraint)
import           Data.Functor.Identity (Identity(..))
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Proxy (Proxy(..))
import           GHC.Generics (Generic)
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

-- | A type scheme representing a polymorphic type.
data Scheme varTypes typ k = Scheme
    { _sForAlls :: Tree varTypes QVars
    , _sTyp :: Tie k typ
    } deriving Generic

newtype QVars typ = QVars
    (Map (QVar (RunKnot typ)) (TypeConstraintsOf (RunKnot typ)))
    deriving stock Generic

instance
    ( Ord (QVar (RunKnot typ))
    , Semigroup (TypeConstraintsOf (RunKnot typ))
    ) =>
    Semigroup (QVars typ) where
    QVars m <> QVars n = QVars (Map.unionWith (<>) m n)

instance
    ( Ord (QVar (RunKnot typ))
    , Semigroup (TypeConstraintsOf (RunKnot typ))
    ) =>
    Monoid (QVars typ) where
    mempty = QVars Map.empty

instance
    (Pretty (Tree varTypes QVars), Pretty (Tie k typ)) =>
    Pretty (Scheme varTypes typ k) where

    pPrintPrec lvl p (Scheme forAlls typ) =
        pPrintPrec lvl 0 forAlls <+>
        pPrintPrec lvl 0 typ
        & maybeParens (p > 0)

instance
    (Pretty (TypeConstraintsOf typ), Pretty (QVar typ)) =>
    Pretty (Tree QVars typ) where

    pPrint (QVars qvars) =
        Map.toList qvars
        <&> printVar
        <&> (Pretty.text "∀" <>) <&> (<> Pretty.text ".") & Pretty.hsep
        where
            printVar (q, c)
                | cP == mempty = pPrint q
                | otherwise = pPrint q <> Pretty.text "(" <> cP <> Pretty.text ")"
                where
                    cP = pPrint c

instance (c (Scheme v t), Recursive c t) => Recursive c (Scheme v t)

Lens.makeLenses ''Scheme
Lens.makePrisms ''QVars
makeChildren ''Scheme

type instance Lens.Index (QVars typ) = QVar (RunKnot typ)
type instance Lens.IxValue (QVars typ) = TypeConstraintsOf (RunKnot typ)

instance Ord (QVar (RunKnot typ)) => Lens.Ixed (QVars typ)

instance Ord (QVar (RunKnot typ)) => Lens.At (QVars typ) where
    at k = _QVars . Lens.at k

newtype QVarInstances k typ = QVarInstances (Map (QVar (RunKnot typ)) (k typ))
    deriving stock Generic
Lens.makePrisms ''QVarInstances

{-# INLINE makeQVarInstancesInScope #-}
makeQVarInstancesInScope ::
    Unify m typ =>
    Tree QVars typ -> m (Tree (QVarInstances (UVarOf m)) typ)
makeQVarInstancesInScope (QVars foralls) =
    traverse makeSkolem foralls <&> QVarInstances
    where
        makeSkolem c = scopeConstraints >>= newVar binding . USkolem . (c <>)

{-# INLINE makeQVarInstances #-}
makeQVarInstances ::
    Unify m typ =>
    Tree QVars typ -> m (Tree (QVarInstances (UVarOf m)) typ)
makeQVarInstances (QVars foralls) =
    traverse (newVar binding . USkolem) foralls <&> QVarInstances

{-# INLINE schemeBodyToType #-}
schemeBodyToType ::
    (Unify m typ, HasChild varTypes typ, Ord (QVar typ)) =>
    Tree varTypes (QVarInstances (UVarOf m)) -> Tree typ (UVarOf m) -> m (Tree (UVarOf m) typ)
schemeBodyToType foralls x =
    case x ^? quantifiedVar >>= getForAll of
    Nothing -> newTerm x
    Just r -> pure r
    where
        getForAll v = foralls ^? getChild . _QVarInstances . Lens.ix v

{-# INLINE schemeToRestrictedType #-}
schemeToRestrictedType ::
    forall m varTypes typ.
    ( Monad m
    , ChildrenWithConstraint varTypes (Unify m)
    , Recursive (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord) typ
    ) =>
    Tree Pure (Scheme varTypes typ) -> m (Tree (UVarOf m) typ)
schemeToRestrictedType (MkPure (Scheme vars typ)) =
    do
        foralls <- children (Proxy :: Proxy (Unify m)) makeQVarInstancesInScope vars
        wrapM
            (Proxy :: Proxy (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord))
            (schemeBodyToType foralls) typ

{-# INLINE loadBody #-}
loadBody ::
    ( Unify m typ
    , HasChild varTypes typ
    , ChildrenConstraint typ NoConstraint
    , Ord (QVar typ)
    ) =>
    Tree varTypes (QVarInstances (UVarOf m)) ->
    Tree typ (GTerm (UVarOf m)) ->
    m (Tree (GTerm (UVarOf m)) typ)
loadBody foralls x =
    case x ^? quantifiedVar >>= getForAll of
    Just r -> GPoly r & pure
    Nothing ->
        case children proxyNoConstraint (^? _GMono) x of
        Just xm -> newTerm xm <&> GMono
        Nothing -> GBody x & pure
    where
        getForAll v = foralls ^? getChild . _QVarInstances . Lens.ix v

-- | Load scheme into unification monad so that different instantiations share
-- the scheme's monomorphic parts -
-- their unification is O(1) as it is the same shared unification term.
{-# INLINE loadScheme #-}
loadScheme ::
    forall m varTypes typ.
    ( Monad m
    , ChildrenWithConstraint varTypes (Unify m)
    , Recursive (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord `And` HasChildrenConstraint NoConstraint) typ
    ) =>
    Tree Pure (Scheme varTypes typ) ->
    m (Tree (GTerm (UVarOf m)) typ)
loadScheme (MkPure (Scheme vars typ)) =
    do
        foralls <- children (Proxy :: Proxy (Unify m)) makeQVarInstances vars
        wrapM (Proxy :: Proxy (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord `And` HasChildrenConstraint NoConstraint))
            (loadBody foralls) typ

saveH ::
    forall m varTypes typ.
    Recursive (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord) typ =>
    Tree (GTerm (UVarOf m)) typ ->
    StateT (Tree varTypes QVars, [m ()]) m (Tree Pure typ)
saveH (GBody x) =
    recursiveChildren
    (Proxy :: Proxy (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord))
    saveH x <&> (_Pure #)
saveH (GMono x) =
    unwrapM
    (Proxy :: Proxy (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord))
    f x & lift
    where
        f v =
            semiPruneLookup v
            <&>
            \case
            (_, UTerm t) -> t ^. uBody
            (_, UUnbound{}) -> error "saveScheme of non-toplevel scheme!"
            _ -> error "unexpected state at saveScheme of monomorphic part"
saveH (GPoly x) =
    lookupVar binding x & lift
    >>=
    \case
    USkolem l ->
        do
            r <- scopeConstraints <&> (<> l) >>= newQuantifiedVariable & lift
            Lens._1 . getChild %=
                (\v -> v & _QVars . Lens.at r ?~ l :: Tree QVars typ)
            Lens._2 %= (bindVar binding x (USkolem l) :)
            let result = _Pure . quantifiedVar # r
            UResolved result & bindVar binding x & lift
            pure result
    UResolved v -> pure v
    _ -> error "unexpected state at saveScheme's forall"

saveScheme ::
    ( ChildrenWithConstraint varTypes (QVarHasInstance Ord)
    , FromChildren varTypes
    , Recursive (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord) typ
    ) =>
    Tree (GTerm (UVarOf m)) typ ->
    m (Tree Pure (Scheme varTypes typ))
saveScheme x =
    do
        (t, (v, recover)) <-
            runStateT (saveH x)
            ( fromChildren (Proxy :: Proxy (QVarHasInstance Ord)) (Identity (QVars mempty))
                & runIdentity
            , []
            )
        _Pure # Scheme v t <$ sequence_ recover

type DepsS c v t k = ((c (Tree v QVars), c (Tie k t)) :: Constraint)
deriving instance DepsS Eq   v t k => Eq   (Scheme v t k)
deriving instance DepsS Ord  v t k => Ord  (Scheme v t k)
deriving instance DepsS Show v t k => Show (Scheme v t k)
instance DepsS Binary v t k => Binary (Scheme v t k)
instance DepsS NFData v t k => NFData (Scheme v t k)

type DepsF c t = ((c (TypeConstraintsOf t), c (QVar t)) :: Constraint)
deriving instance DepsF Eq   t => Eq   (Tree QVars t)
deriving instance DepsF Ord  t => Ord  (Tree QVars t)
deriving instance DepsF Show t => Show (Tree QVars t)
instance DepsF Binary t => Binary (Tree QVars t)
instance DepsF NFData t => NFData (Tree QVars t)

type DepsQ c k t = ((c (QVar (RunKnot t)), c (k t)) :: Constraint)
deriving instance DepsQ Eq   k t => Eq   (QVarInstances k t)
deriving instance DepsQ Ord  k t => Ord  (QVarInstances k t)
deriving instance DepsQ Show k t => Show (QVarInstances k t)
instance DepsQ Binary k t => Binary (QVarInstances k t)
instance DepsQ NFData k t => NFData (QVarInstances k t)
