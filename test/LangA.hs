{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | A test language with locally-nameless variable scoping and type signatures with for-alls
module LangA where

import TypeLang

import Control.Applicative
import qualified Control.Lens as Lens
import Control.Lens.Operators
import Control.Monad.Except
import Control.Monad.RWS
import Control.Monad.Reader
import Control.Monad.ST
import Control.Monad.ST.Class (MonadST (..))
import Data.Constraint
import Data.STRef
import Hyper
import Hyper.Class.Infer.Infer1
import Hyper.Infer
import Hyper.Syntax
import Hyper.Syntax.NamelessScope
import Hyper.Syntax.NamelessScope.InvDeBruijn
import Hyper.Syntax.Scheme
import Hyper.Unify
import Hyper.Unify.Binding
import Hyper.Unify.Binding.ST
import Hyper.Unify.New
import Hyper.Unify.QuantifiedVar
import Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import Text.PrettyPrint.HughesPJClass (Pretty (..), maybeParens)

import Prelude

data LangA v h
    = ALam (Scope LangA v h)
    | AVar (ScopeVar LangA v h)
    | AApp (App (LangA v) h)
    | ATypeSig (TypeSig Types (LangA v) h)
    | ALit Int

makeHTraversableAndBases ''LangA
makeHasHPlain [''LangA]

instance RNodes (LangA v)
instance Recursively HFunctor (LangA h)
instance Recursively HFoldable (LangA h)
instance RTraversable (LangA h)

type instance InferOf (LangA h) = ANode Typ

instance Recursively (InferOfConstraint HFunctor) (LangA h)
instance Recursively (InferOfConstraint HFoldable) (LangA h)

instance HasInferredType (LangA h) where
    type TypeOf (LangA h) = Typ
    inferredType _ = _ANode

instance InvDeBruijnIndex v => Pretty (LangA v ('AHyperType Pure)) where
    pPrintPrec lvl p (ALam (Scope expr)) =
        Pretty.hcat
            [ Pretty.text "λ("
            , pPrint (1 + deBruijnIndexMax (Proxy @v))
            , Pretty.text ")."
            ]
            <+> pPrintPrec lvl 0 expr
            & maybeParens (p > 0)
    pPrintPrec _ _ (AVar (ScopeVar v)) =
        Pretty.text "#" <> pPrint (inverseDeBruijnIndex # v)
    pPrintPrec lvl p (AApp (App f x)) =
        pPrintPrec lvl p f <+> pPrintPrec lvl p x
    pPrintPrec lvl p (ATypeSig typeSig) = pPrintPrec lvl p typeSig
    pPrintPrec _ _ (ALit i) = pPrint i

instance HasTypeOf1 LangA where
    type TypeOf1 LangA = Typ
    typeAst _ = Dict

instance HasInferOf1 LangA where
    type InferOf1 LangA = ANode Typ
    type InferOf1IndexConstraint LangA = DeBruijnIndex
    hasInferOf1 _ = Dict

type TermInfer1Deps env m =
    ( MonadScopeLevel m
    , MonadReader env m
    , HasScopeTypes (UVarOf m) Typ env
    , MonadInstantiate m Typ
    , MonadInstantiate m Row
    )

instance TermInfer1Deps env m => Infer1 m LangA where
    inferMonad = Sub Dict

instance (DeBruijnIndex h, TermInfer1Deps env m) => Infer m (LangA h) where
    inferBody (ALit x) = newTerm TInt <&> (ALit x,) . MkANode
    inferBody (AVar x) = inferBody x <&> Lens._1 %~ AVar
    inferBody (ALam x) =
        do
            (b, t) <- inferBody x
            TFun t & newTerm <&> (ALam b,) . MkANode
    inferBody (AApp x) = inferBody x <&> Lens._1 %~ AApp
    inferBody (ATypeSig x) = inferBody x <&> Lens._1 %~ ATypeSig

-- Monads for inferring `LangA`:

data LangAInferEnv v = LangAInferEnv
    { _iaScopeTypes :: ScopeTypes Typ # v
    , _iaScopeLevel :: ScopeLevel
    , _iaInstantiations :: Types # QVarInstances v
    }
Lens.makeLenses ''LangAInferEnv

emptyLangAInferEnv :: LangAInferEnv v
emptyLangAInferEnv =
    LangAInferEnv
        mempty
        (ScopeLevel 0)
        (hpure (Proxy @OrdQVar #> QVarInstances mempty))

instance HasScopeTypes v Typ (LangAInferEnv v) where scopeTypes = iaScopeTypes

newtype PureInferA a
    = PureInferA
        ( RWST
            (LangAInferEnv UVar)
            ()
            PureInferState
            (Either (TypeError # Pure))
            a
        )
    deriving newtype
        ( Functor
        , Applicative
        , Monad
        , MonadError (TypeError # Pure)
        , MonadReader (LangAInferEnv UVar)
        , MonadState PureInferState
        )

execPureInferA :: PureInferA a -> Either (TypeError # Pure) a
execPureInferA (PureInferA act) =
    runRWST act emptyLangAInferEnv emptyPureInferState
        <&> (^. Lens._1)

type instance UVarOf PureInferA = UVar

instance MonadScopeLevel PureInferA where
    localLevel = local (iaScopeLevel . _ScopeLevel +~ 1)

instance UnifyGen PureInferA Typ where
    scopeConstraints _ = Lens.view iaScopeLevel

instance UnifyGen PureInferA Row where
    scopeConstraints _ = Lens.view iaScopeLevel <&> RowConstraints mempty

instance MonadQuantify ScopeLevel Name PureInferA where
    newQuantifiedVariable _ =
        pisFreshQVars . tTyp . Lens._Wrapped <<+= 1 <&> Name . ('t' :) . show

instance MonadQuantify RConstraints Name PureInferA where
    newQuantifiedVariable _ =
        pisFreshQVars . tRow . Lens._Wrapped <<+= 1 <&> Name . ('r' :) . show

instance Unify PureInferA Typ where
    binding = bindingDict (pisBindings . tTyp)

instance Unify PureInferA Row where
    binding = bindingDict (pisBindings . tRow)
    structureMismatch = rStructureMismatch

instance MonadInstantiate PureInferA Typ where
    localInstantiations (QVarInstances x) =
        local (iaInstantiations . tTyp . _QVarInstances <>~ x)
    lookupQVar x =
        Lens.view (iaInstantiations . tTyp . _QVarInstances . Lens.at x)
            >>= maybe (throwError (QVarNotInScope x)) pure

instance MonadInstantiate PureInferA Row where
    localInstantiations (QVarInstances x) =
        local (iaInstantiations . tRow . _QVarInstances <>~ x)
    lookupQVar x =
        Lens.view (iaInstantiations . tRow . _QVarInstances . Lens.at x)
            >>= maybe (throwError (QVarNotInScope x)) pure

newtype STInferA s a
    = STInferA
        ( ReaderT
            (LangAInferEnv (STUVar s), STNameGen s)
            (ExceptT (TypeError # Pure) (ST s))
            a
        )
    deriving newtype
        ( Functor
        , Applicative
        , Monad
        , MonadST
        , MonadError (TypeError # Pure)
        , MonadReader (LangAInferEnv (STUVar s), STNameGen s)
        )

execSTInferA :: STInferA s a -> ST s (Either (TypeError # Pure) a)
execSTInferA (STInferA act) =
    do
        qvarGen <- Types <$> (newSTRef 0 <&> Const) <*> (newSTRef 0 <&> Const)
        runReaderT act (emptyLangAInferEnv, qvarGen) & runExceptT

type instance UVarOf (STInferA s) = STUVar s

instance MonadScopeLevel (STInferA s) where
    localLevel = local (Lens._1 . iaScopeLevel . _ScopeLevel +~ 1)

instance UnifyGen (STInferA s) Typ where
    scopeConstraints _ = Lens.view (Lens._1 . iaScopeLevel)

instance UnifyGen (STInferA s) Row where
    scopeConstraints _ = Lens.view (Lens._1 . iaScopeLevel) <&> RowConstraints mempty

instance MonadQuantify ScopeLevel Name (STInferA s) where
    newQuantifiedVariable _ = newStQuantified (Lens._2 . tTyp) <&> Name . ('t' :) . show

instance MonadQuantify RConstraints Name (STInferA s) where
    newQuantifiedVariable _ = newStQuantified (Lens._2 . tRow) <&> Name . ('r' :) . show

instance Unify (STInferA s) Typ where
    binding = stBinding

instance Unify (STInferA s) Row where
    binding = stBinding
    structureMismatch = rStructureMismatch

instance MonadInstantiate (STInferA s) Typ where
    localInstantiations (QVarInstances x) =
        local (Lens._1 . iaInstantiations . tTyp . _QVarInstances <>~ x)
    lookupQVar x =
        Lens.view (Lens._1 . iaInstantiations . tTyp . _QVarInstances . Lens.at x)
            >>= maybe (throwError (QVarNotInScope x)) pure

instance MonadInstantiate (STInferA s) Row where
    localInstantiations (QVarInstances x) =
        local (Lens._1 . iaInstantiations . tRow . _QVarInstances <>~ x)
    lookupQVar x =
        Lens.view (Lens._1 . iaInstantiations . tRow . _QVarInstances . Lens.at x)
            >>= maybe (throwError (QVarNotInScope x)) pure

instance HasScheme Types PureInferA Typ
instance HasScheme Types PureInferA Row
instance HasScheme Types (STInferA s) Typ
instance HasScheme Types (STInferA s) Row
