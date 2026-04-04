/*
 * ZipArchiveReader.cpp
 *
 *  Created on: 9 Nov 2016
 *      Author: clarkson
 */

#include <od/extras/ZipArchiveReader.h>
#define BUILDOPT_VERBOSE
#define BUILDOPT_DEBUG_LEVEL 1
#include <hal/log.h>
#include <hal/fileops.h>
#include <string.h>
#include <stdio.h>

namespace od
{

    ZipArchiveReader::ZipArchiveReader()
    {
    }

    ZipArchiveReader::~ZipArchiveReader()
    {
        close();
    }

    bool ZipArchiveReader::open(const char *filename)
    {
        close();
        mLastError.clear();

        // Pre-flight checks for better diagnostics
        if (!pathExists(filename))
        {
            mLastError = std::string("Path does not exist: ") + filename;
            logError("ZipArchiveReader: %s", mLastError.c_str());
            return false;
        }

        if (isDirectory(filename))
        {
            mLastError = std::string("Path is a directory, not a file: ") + filename;
            logError("ZipArchiveReader: %s", mLastError.c_str());
            return false;
        }

        uint64_t fileSize = 0;
        uint32_t attrs = 0;
        getFileInfo(filename, &attrs, &fileSize);
        logInfo("ZipArchiveReader: opening %s (%llu bytes)", filename, (unsigned long long)fileSize);

        if (fileSize == 0)
        {
            mLastError = std::string("File is empty (0 bytes): ") + filename;
            logError("ZipArchiveReader: %s", mLastError.c_str());
            return false;
        }

        // Now try to open the archive.
        memset(&mArchive, 0, sizeof(mArchive));
        mIsOpen = mz_zip_reader_init_file(&mArchive, filename, 0);
        if (!mIsOpen)
        {
            char buf[256];
            snprintf(buf, sizeof(buf), "Not a valid zip archive (%llu bytes): %s", (unsigned long long)fileSize, filename);
            mLastError = buf;
            logError("ZipArchiveReader: %s", mLastError.c_str());
        }
        else
        {
            logInfo("ZipArchiveReader: opened %s with %d entries.", filename, mz_zip_reader_get_num_files(&mArchive));
        }
        return mIsOpen;
    }

    void ZipArchiveReader::close()
    {
        if (mIsOpen)
        {
            mz_zip_reader_end(&mArchive);
            mIsOpen = false;
        }
    }

    bool ZipArchiveReader::exists(const char *filename)
    {
        if (mIsOpen)
        {
            int fileIndex = mz_zip_reader_locate_file(&mArchive, filename, NULL, getFlags());
            if (fileIndex >= 0)
            {
                return true;
            }
        }

        return false;
    }

    bool ZipArchiveReader::extract(const char *from, const char *to)
    {
        if (mIsOpen)
        {
            return mz_zip_reader_extract_file_to_file(&mArchive, from, to, getFlags());
        }
        else
        {
            return false;
        }
    }

    std::string ZipArchiveReader::extractToString(const char *filename)
    {
        if (mIsOpen)
        {
            size_t nbytes = 0;
            char *buffer = (char *)mz_zip_reader_extract_file_to_heap(&mArchive, filename, &nbytes, getFlags());
            if (nbytes > 0 && buffer)
            {
                return std::string(buffer, nbytes);
            }
        }

        return "";
    }

    void ZipArchiveReader::setIgnorePath(bool enable)
    {
        mIgnorePath = enable;
    }

    void ZipArchiveReader::setCaseSensitive(bool enable)
    {
        mCaseSensitive = enable;
    }

    mz_uint ZipArchiveReader::getFlags()
    {
        mz_uint flag = 0;
        if (mIgnorePath)
        {
            flag |= MZ_ZIP_FLAG_IGNORE_PATH;
        }

        if (mCaseSensitive)
        {
            flag |= MZ_ZIP_FLAG_CASE_SENSITIVE;
        }

        return flag;
    }

    int ZipArchiveReader::getFileCount()
    {
        if (mIsOpen)
        {
            return (int)mz_zip_reader_get_num_files(&mArchive);
        }
        else
        {
            return 0;
        }
    }

    std::string ZipArchiveReader::getFilename(int index)
    {
        if (mIsOpen)
        {
            mz_zip_archive_file_stat stat;
            if (mz_zip_reader_file_stat(&mArchive, index, &stat))
            {
                return stat.m_filename;
            }
        }
        return "";
    }

} /* namespace od */
