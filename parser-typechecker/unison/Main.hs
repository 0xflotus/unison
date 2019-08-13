{-# LANGUAGE TemplateHaskell #-}

module Main where

import           Safe                           ( headMay )
import           System.Environment             ( getArgs )
import qualified Unison.Codebase.FileCodebase  as FileCodebase
import qualified Unison.CommandLine.Main       as CommandLine
import qualified Unison.Runtime.Rt1IO          as Rt1
import qualified Unison.Codebase.Path          as Path
import qualified Development.GitRev            as GitRev


main :: IO ()
main = do
  args               <- getArgs
  -- hSetBuffering stdout NoBuffering -- cool
  (dir, theCodebase) <- FileCodebase.ensureCodebaseInitialized
  putStrLn $ "Version: " ++ $(GitRev.gitDescribe')
  let initialPath = Path.absoluteEmpty
      launch      = CommandLine.main dir
                                     initialPath
                                     (headMay args)
                                     (pure Rt1.runtime)
                                     theCodebase
  launch
