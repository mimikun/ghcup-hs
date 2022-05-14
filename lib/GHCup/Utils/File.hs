{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

module GHCup.Utils.File (
  mergeFileTree,
  copyFileE,
  findFilesDeep,
  getDirectoryContentsRecursive,
  getDirectoryContentsRecursiveBFS,
  getDirectoryContentsRecursiveDFS,
  getDirectoryContentsRecursiveUnsafe,
  getDirectoryContentsRecursiveBFSUnsafe,
  getDirectoryContentsRecursiveDFSUnsafe,
  recordedInstallationFile,
  module GHCup.Utils.File.Common,

  executeOut,
  execLogged,
  exec,
  toProcessError,
  chmod_755,
  isBrokenSymlink,
  copyFile,
  deleteFile,
  install,
  removeEmptyDirectory,
) where

import GHCup.Utils.Dirs
import GHCup.Utils.File.Common
#if IS_WINDOWS
import GHCup.Utils.File.Windows
#else
import GHCup.Utils.File.Posix
#endif
import           GHCup.Errors
import           GHCup.Types
import           GHCup.Types.Optics
import           GHCup.Utils.Prelude

import           Text.Regex.Posix
import           Control.Exception.Safe
import           Haskus.Utils.Variant.Excepts
import           Control.Monad.Reader
import           System.FilePath
import           Text.PrettyPrint.HughesPJClass (prettyShow)

import qualified Data.Text                     as T
import qualified Streamly.Prelude              as S


mergeFileTree :: (MonadMask m, S.MonadAsync m, MonadReader env m, HasDirs env)
              => GHCupPath                       -- ^ source base directory from which to install findFiles
              -> InstallDirResolved              -- ^ destination base dir
              -> Tool
              -> GHCTargetVersion
              -> (FilePath -> FilePath -> m ())  -- ^ file copy operation
              -> m ()
mergeFileTree sourceBase destBase tool v' copyOp = do
  -- These checks are not atomic, but we perform them to have
  -- the opportunity to abort before copying has started.
  --
  -- The actual copying might still fail.
  liftIO $ baseCheck (fromGHCupPath sourceBase)
  liftIO $ destCheck (fromInstallDir destBase)

  recFile <- recordedInstallationFile tool v'
  case destBase of
    IsolateDirResolved _ -> pure ()
    _ -> do
      whenM (liftIO $ doesFileExist recFile) $ throwIO $ userError ("mergeFileTree: DB file " <> recFile <> " already exists!")
      liftIO $ createDirectoryIfMissing True (takeDirectory recFile)

  flip S.mapM_ (getDirectoryContentsRecursive sourceBase) $ \f -> do
    copy f
    recordInstalledFile f recFile
    pure f

 where
  recordInstalledFile f recFile = do
    case destBase of
      IsolateDirResolved _ -> pure ()
      _ -> liftIO $ appendFile recFile (f <> "\n")

  copy source = do
    let dest = fromInstallDir destBase </> source
        src  = fromGHCupPath sourceBase </> source

    when (isAbsolute source)
      $ throwIO $ userError ("mergeFileTree: source file " <> source <> " is not relative!")

    liftIO . createDirectoryIfMissing True . takeDirectory $ dest

    copyOp src dest


  baseCheck src = do
      when (isRelative src)
        $ throwIO $ userError ("mergeFileTree: source base directory " <> src <> " is not absolute!")
      whenM (not <$> doesDirectoryExist src)
        $ throwIO $ userError ("mergeFileTree: source base directory " <> src <> " does not exist!")
  destCheck dest = do
      when (isRelative dest)
        $ throwIO $ userError ("mergeFileTree: destination base directory " <> dest <> " is not absolute!")



copyFileE :: (CopyError :< xs, MonadCatch m, MonadIO m) => FilePath -> FilePath -> Bool -> Excepts xs m ()
copyFileE from to = handleIO (throwE . CopyError . show) . liftIO . copyFile from to


-- | List all the files in a directory and all subdirectories.
--
-- The order places files in sub-directories after all the files in their
-- parent directories. The list is generated lazily so is not well defined if
-- the source directory structure changes before the list is used.
--
-- depth first
getDirectoryContentsRecursiveDFS :: (MonadCatch m, S.MonadAsync m, MonadMask m)
                                 => GHCupPath
                                 -> S.SerialT m FilePath
getDirectoryContentsRecursiveDFS (fromGHCupPath -> fp) = getDirectoryContentsRecursiveDFSUnsafe fp

-- breadth first
getDirectoryContentsRecursiveBFS :: (MonadCatch m, S.MonadAsync m, MonadMask m)
                                 => GHCupPath
                                 -> S.SerialT m FilePath
getDirectoryContentsRecursiveBFS (fromGHCupPath -> fp) = getDirectoryContentsRecursiveBFSUnsafe fp


getDirectoryContentsRecursive :: (MonadCatch m, S.MonadAsync m, MonadMask m)
                              => GHCupPath
                              -> S.SerialT m FilePath
getDirectoryContentsRecursive = getDirectoryContentsRecursiveBFS

getDirectoryContentsRecursiveUnsafe :: (MonadCatch m, S.MonadAsync m, MonadMask m)
                                    => FilePath
                                    -> S.SerialT m FilePath
getDirectoryContentsRecursiveUnsafe = getDirectoryContentsRecursiveBFSUnsafe

findFilesDeep :: GHCupPath -> Regex -> IO [FilePath]
findFilesDeep path regex =
  S.toList $ S.filter (match regex) $ getDirectoryContentsRecursive path


recordedInstallationFile :: ( MonadReader env m
                            , HasDirs env
                            )
                         => Tool
                         -> GHCTargetVersion
                         -> m FilePath
recordedInstallationFile t v' = do
  Dirs {..}  <- getDirs
  pure (fromGHCupPath dbDir </> prettyShow t </> T.unpack (tVerToText v'))

