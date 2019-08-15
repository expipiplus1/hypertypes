{-# LANGUAGE UndecidableInstances, ScopedTypeVariables, TemplateHaskell, FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module AST.Knot.Prune
    ( Prune(..)
    ) where

import AST
import AST.Class.Monad (KMonad(..))
import AST.Class.Traversable
import AST.Class.Unify (Unify)
import AST.Combinator.Compose (Compose(..))
import AST.Combinator.ANode (ANode(..))
import AST.Infer
import AST.Unify.New (newUnbound)
import Control.DeepSeq (NFData)
import Control.Lens (makePrisms)
import Control.Lens.Operators
import Data.Binary (Binary)
import Data.Constraint
import Data.Proxy (Proxy(..))
import GHC.Generics (Generic)

import Prelude.Compat

data Prune k =
    Pruned | Unpruned (Node k Prune)
    deriving Generic

instance KNodes Prune where
    type NodeTypesOf Prune = ANode Prune
    {-# INLINE combineConstraints #-}
    combineConstraints _ _ _ = Dict

makePrisms ''Prune
makeKTraversableAndBases ''Prune
makeZipMatch ''Prune

-- `KPointed` and `KApplicative` instances in the spirit of `Maybe`

instance KPointed Prune where
    pureK = Unpruned
    pureKWithConstraint _ = Unpruned

instance KApply Prune where
    zipK Pruned _ = Pruned
    zipK _ Pruned = Pruned
    zipK (Unpruned x) (Unpruned y) = Pair x y & Unpruned

instance KMonad Prune where
    joinK (MkCompose Pruned) = Pruned
    joinK (MkCompose (Unpruned (MkCompose Pruned))) = Pruned
    joinK (MkCompose (Unpruned (MkCompose (Unpruned (MkCompose x))))) =
        withDict (r x) $
        mapKWith (Proxy @'[Recursively KFunctor]) joinK x
        & Unpruned
        where
            r :: Recursively KFunctor l => Tree l k -> RecursiveDict l KFunctor
            r _ = recursive

instance c Prune => Recursively c Prune where
    {-# INLINE combineRecursive #-}
    combineRecursive = Dict

type instance InferOf (Compose Prune t) = InferOf t

instance
    ( KApplicative (InferOf t), KTraversable (InferOf t)
    , NodesConstraint (InferOf t) $ Unify m
    , KFunctor t, Infer m t
    ) =>
    Infer m (Compose Prune t) where
    inferBody (MkCompose Pruned) =
        sequencePureKWith (Proxy @'[Unify m]) newUnbound
        <&> InferRes (MkCompose Pruned)
    inferBody (MkCompose (Unpruned (MkCompose x))) =
        mapK
        (\(MkCompose (InferChild i)) -> i <&> inRep %~ MkCompose & InferChild)
        x
        & inferBody
        <&> inferResBody %~ MkCompose . Unpruned . MkCompose

deriving instance Eq   (Node k Prune) => Eq   (Prune k)
deriving instance Ord  (Node k Prune) => Ord  (Prune k)
deriving instance Show (Node k Prune) => Show (Prune k)
instance Binary (Node k Prune) => Binary (Prune k)
instance NFData (Node k Prune) => NFData (Prune k)
