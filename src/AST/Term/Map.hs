{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, StandaloneDeriving, UndecidableInstances, DeriveGeneric, TypeFamilies, FlexibleInstances, MultiParamTypeClasses #-}

module AST.Term.Map
    ( TermMap(..), _TermMap
    ) where

import           AST (Tie, Recursive(..), RecursiveConstraint, makeChildren)
import           AST.Class.ZipMatch (ZipMatch(..), Both(..))
import           Control.DeepSeq (NFData)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Data.Binary (Binary)
import           Data.Map (Map)
import qualified Data.Map as Map
import           GHC.Generics (Generic)

import           Prelude.Compat

newtype TermMap k expr f = TermMap (Map k (Tie f expr))
    deriving Generic

deriving instance (Eq   k, Eq   (Tie f expr)) => Eq   (TermMap k expr f)
deriving instance (Ord  k, Ord  (Tie f expr)) => Ord  (TermMap k expr f)
deriving instance (Show k, Show (Tie f expr)) => Show (TermMap k expr f)
instance (Binary k, Binary (Tie f expr)) => Binary (TermMap k expr f)
instance (NFData k, NFData (Tie f expr)) => NFData (TermMap k expr f)

Lens.makePrisms ''TermMap
makeChildren [''TermMap]

instance RecursiveConstraint (TermMap k expr) constraint => Recursive constraint (TermMap k expr)

instance Eq k => ZipMatch (TermMap k expr) where
    zipMatch (TermMap x) (TermMap y)
        | Map.size x /= Map.size y = Nothing
        | otherwise =
            zipMatchList (Map.toList x) (Map.toList y)
            <&> traverse . Lens._2 %~ uncurry Both
            <&> TermMap . Map.fromAscList

zipMatchList :: Eq k => [(k, a)] -> [(k, b)] -> Maybe [(k, (a, b))]
zipMatchList [] [] = Just []
zipMatchList ((k0, v0) : xs) ((k1, v1) : ys)
    | k0 == k1 =
        zipMatchList xs ys <&> ((k0, (v0, v1)) :)
zipMatchList _ _ = Nothing