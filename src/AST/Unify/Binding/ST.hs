{-# LANGUAGE TemplateHaskell #-}

-- | Unification variables binding in the 'Data.ST.ST' monad

module AST.Unify.Binding.ST
    ( STUVar(..), _STUVar
    , stBinding
    ) where

import           AST.Class.Unify (BindingDict(..))
import           AST.Unify.Term (UTerm(..))
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.ST.Class (MonadST(..))
import           Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)

import           Prelude.Compat

-- | A unification variable in the 'Data.ST.ST' monad
newtype STUVar s t = STUVar (STRef s (UTerm (STUVar s) t))
    deriving stock Eq
Lens.makePrisms ''STUVar

-- | A 'BindingDict' for 'STUVar's
{-# INLINE stBinding #-}
stBinding ::
    MonadST m =>
    BindingDict (STUVar (World m)) m t
stBinding =
    BindingDict
    { lookupVar = liftST . readSTRef . (^. _STUVar)
    , newVar = \t -> newSTRef t & liftST <&> STUVar
    , bindVar = \v t -> writeSTRef (v ^. _STUVar) t & liftST
    }
