<%@  Class="PhotoHandler.Album" Language="c#" %>
// Photo Handler //<!--
//////////////////////////////////////////////////////////////////////////////////////////////
// Photo Handler
// Originally created by Dmitry Robsman
// Modified by Bertrand Le Roy
// with the participation of David Ebbo
// http://photohandler.codeplex.com/
//////////////////////////////////////////////////////////////////////////////////////////////
// Uses a modified version of the Metadata public domain library by
// Drew Noakes (drew@drewnoakes.com)
// and adapted for .NET by Renaud Ferret (renaud91@free.fr)
// The library can be downloaded from
// http://renaud91.free.fr/MetaDataExtractor/
//////////////////////////////////////////////////////////////////////////////////////////////
//
// Version 3.0
//
// What's new:
// - MetaDataExtractor inlined in the handler, no more need for the dll in bin.
// - Thumbnails now constructed as a sprite strip instead of individual images.
// - Namespace moved to PhotoHandler.
// - Output and client caching.
//
//////////////////////////////////////////////////////////////////////////////////////////////
// Version 2.1
// What was new:
// - Support for Windows XP title and comments
// - Added base class for ImageInfo and AlbumFolderInfo
// - Added NavigationMode property
//////////////////////////////////////////////////////////////////////////////////////////////
// Version 2.0
// What was new:
// - Default CSS embedded into the handler
// - Fixed the mirrored folder thumbnail
// - Now using strongly-typed HtmlTextWriter for default rendering
// - Handler can be used as a control (register as a user control)
// - Control can be fully templated for customized rendering
//////////////////////////////////////////////////////////////////////////////////////////////

#region using
using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net.Mime;
using System.Reflection;
using System.Text;
using System.Web;
using System.Web.Caching;
using System.Web.UI;

using Com.Utilities;
using Com.Drew.Imaging.Jpg;
using Com.Drew.Lang;
using Com.Drew.Metadata.Exif;
using Com.Drew.Metadata.Jpeg;
using Com.Drew.Metadata.Iptc;

using MetadataDirectory = Com.Drew.Metadata.Directory;
using Metadata = Com.Drew.Metadata.Metadata;
using Tag = Com.Drew.Metadata.Tag;
#endregion

namespace PhotoHandler
{
    /// <summary>
    /// Static methods and constants for use by the Album class.
    /// </summary>
    internal static class ImageHelper
    {
        // the following constants constitute the handler's configuration:

        /// <summary>
        /// Size in pixels of the thumbnails.
        /// </summary>
        public const int ThumbnailSize = 120;

        /// <summary>
        /// Size in pixels of the preview images.
        /// </summary>
        public const int PreviewSize = 700;

        /// <summary>
        /// Maximum size of the thumbnail caption in chars.
        /// 0 to disable caption.        
        /// </summary>
        public static int ThumbnailCaptionMaxChars = 10;

        /// <summary>
        /// The background color of the image thumbnails and previews.
        /// </summary>
        private static readonly Color BackGround = Color.Black;

        /// <summary>
        /// The color used to draw borders around image thumbnails and previews.
        /// </summary>
        private static readonly Color BorderColor = Color.Beige;

        /// <summary>
        /// The width in pixels of the thumbnail border.
        /// </summary>
        private static readonly float ThumbnailBorderWidth = 2;

        /// <summary>
        /// The width in pixels of the image previews.
        /// </summary>
        private static readonly float PreviewBorderWidth = 3;

        /// <summary>
        /// The color of the shadow that's drawn around up folder stacked image thumbnails.
        /// </summary>
        private static readonly Color UpFolderBorderColor = Color.FromArgb(90, Color.Black);

        /// <summary>
        /// The width in pixels of the shadow that's drawn around up folder stacked image thumbnails.
        /// </summary>
        private static readonly float UpFolderBorderWidth = 2;

        /// <summary>
        /// The color of the arrow that's drawn on up folder thumbnails.
        /// </summary>
        private static readonly Color UpArrowColor = Color.FromArgb(200, Color.Beige);

        /// <summary>
        /// The width of the arrow that's drawn on up folder thumbnails.
        /// </summary>
        private static readonly float UpArrowWidth = 4;

        /// <summary>
        /// The relative size of the arrow that's drawn on up folder thumbnails.
        /// </summary>
        private static readonly float UpArrowSize = 0.125F;

        /// <summary>
        /// The number of images on the up folder thumbnail stack.
        /// </summary>
        private static readonly int UpFolderStackHeight = 3;

        /// <summary>
        /// The quality (between 0 and 100) of the thumbnail JPEGs.
        /// </summary>
        private static readonly long ThumbnailJpegQuality = 75L;

        /// <summary>
        /// Location of the cache.
        /// Can be Disk (recommended), Memory or None.
        /// </summary>
        private const CacheLocation Caching = CacheLocation.Disk;

        /// <summary>
        /// If using memory cache, the duration in minutes of the sliding expiration.
        /// </summary>
        private const int MemoryCacheSlidingDuration = 10;

        /// <summary>
        /// The duration in minutes of the client sliding expiration.
        /// </summary>
        private const int ClientCacheSlidingDuration = 10;

        /// <summary>
        /// Default location for cache dir; if not specified, defaults to a subdirectory of web app
        /// </summary>
        public static string ImageCacheDir = null;

        /// <summary>
        /// Root of pictures; if not specified, defaults to this file's directory.
        /// For development purposes only; trying to access the full-size picture will yield a 404.
        /// </summary>
        public static string PicturesDir = null;

        /// <summary>
        /// If true, invalidate cache everytime the code changes. Useful when doing dev work
        /// </summary>
        public static bool InvalidateCacheOnCodeChanges = false;

        /// <summary>
        /// The default CSS that's requested by the header.
        /// </summary>
        private static readonly string Css = @"
body, td {
    font-family: Verdana, Arial, Helvetica;
    font-size: xx-small;
    color: Gray;
    background-color: " + FormatColor(BackGround) + @";
}

a {
    color: White;
    text-decoration: none;
}

img {
    border: none;
}

img.blank {
    border: none;
    width: " + ThumbnailSize + @"px;
    height: " + ThumbnailSize + @"px;
}

.album {
}

.albumFloat {
    float: left;
    clear: none;
    text-align: center;
    margin-right: 8px;
    margin-bottom: 4px;
}

.albumDetails {
    clear: both;
}

.albumDetailsLink {
}

.albumLegend:hover {
    text-decoration: underline;
}

.albumMetaSectionHead {
    background-color: Gray;
    color: White;
    font-weight: bold;
}

.albumMetaName {
    font-weight: bold;
}

.albumMetaValue {
}
";

        private static readonly byte[] _blankGif =
            Convert.FromBase64String("R0lGODlhAQABAID/AMDAwAAAACH5BAEAAAAALAAAAAABAAEAAAEBMgA7");

        /// <summary>
        /// Static constructor that sets up the caching directory
        /// </summary>
        static ImageHelper()
        {
#pragma warning disable 162
            if (Caching == CacheLocation.Disk)
            {
                if (string.IsNullOrWhiteSpace(ImageCacheDir))
                {
                    ImageCacheDir = Path.Combine(HttpRuntime.AppDomainAppPath, @"_AlbumCache");
                }
                Directory.CreateDirectory(ImageCacheDir);
            }
#pragma warning restore 162
        }

        /// <summary>
        /// Formats a color as an HTML color string.
        /// </summary>
        /// <param name="c">The color to format.</param>
        /// <returns>The string representation of the color in the form #RRGGBB.</returns>
        public static string FormatColor(Color c)
        {
            return '#' + c.R.ToString("X2") + c.G.ToString("X2") + c.B.ToString("X2");
        }

        /// <summary>
        /// Gets the path for a cached image and its status.
        /// </summary>
        /// <param name="path">The path to the image.</param>
        /// <param name="cachedPath">The physical path of the cached image (out parameter).</param>
        /// <returns>True if the cached image exists and is not outdated.</returns>
        public static bool GetCachedPathAndCheckCacheStatus(
            string path,
            out string cachedPath)
        {

            // Compute last modified time
            DateTime lastModified = DateTime.MinValue;
            if (Directory.Exists(path))
            {
                // Need to scan all contents
                foreach (string entry in Directory.GetDirectories(path))
                {
                    lastModified = MaxTime(lastModified, Directory.GetLastWriteTime(entry));
                }
                foreach (string entry in Directory.GetFiles(path))
                {
                    lastModified = MaxTime(lastModified, File.GetLastWriteTime(entry));
                }
            }
            else
            {
                lastModified = File.GetLastWriteTime(path);
            }
            var srcCode = Path.Combine(HttpRuntime.AppDomainAppPath, "album.ashx");
            if (InvalidateCacheOnCodeChanges && File.Exists(srcCode))
            {
                lastModified = MaxTime(lastModified, File.GetLastWriteTime(srcCode));
            }
            string cacheKey = Path.Combine(path, ".png")
                .Substring(ImageHelper.PicturesDir.Length)
                .Replace('\\', '_')
                .Replace(':', '_');
            cachedPath = Path.Combine(ImageCacheDir, cacheKey);

            return File.Exists(cachedPath) && File.GetLastWriteTime(cachedPath) >= lastModified;
        }

        public static DateTime MaxTime(DateTime d1, DateTime d2)
        {
            return d1 < d2 ? d2 : d1;
        }

        /// <summary>
        /// Outputs a transparent image to the response.
        /// </summary>
        /// <param name="response">The response to write to.</param>
        public static void GenerateBlankImage(HttpResponse response)
        {
            CacheForever(response);
            response.ContentType = MediaTypeNames.Image.Gif;
            response.OutputStream.Write(_blankGif, 0, _blankGif.Length);
            response.Flush();
        }

        private static void CacheForever(HttpResponse response)
        {
            ClientCache(response);
            HttpCachePolicy cache = response.Cache;
            cache.SetValidUntilExpires(true);
            cache.VaryByParams["albummode"] = true;
            cache.SetOmitVaryStar(true);
        }

        private static void ClientCache(HttpResponse response)
        {
            HttpCachePolicy cache = response.Cache;
            DateTime now = DateTime.Now;
            cache.SetCacheability(HttpCacheability.Public);
            cache.SetExpires(now + TimeSpan.FromMinutes(ClientCacheSlidingDuration));
            cache.SetLastModified(now);
        }

        /// <summary>
        /// Sends the default CSS to the response.
        /// </summary>
        /// <param name="response">The response where to write the CSS.</param>
        public static void GenerateCssResponse(HttpResponse response)
        {
            CacheForever(response);
            response.ContentType = "text/css";
            response.Write(Css);
        }

        /// <summary>
        /// Outputs a resized image to the HttpResponse object
        /// </summary>
        /// <param name="imageFile">The image file to serve.</param>
        /// <param name="size">The size in pixels of a bounding square around the reduced image.</param>
        /// <param name="response">The HttpResponse to output to.</param>
        public static void GenerateResizedImageResponse(
            string imageFile,
            int size,
            HttpResponse response)
        {
            ClientCache(response);
            string buildPath = null;

#pragma warning disable 162
            if (Caching == CacheLocation.Disk &&
                GetCachedPathAndCheckCacheStatus(imageFile, out buildPath))
            {

                WriteImage(buildPath, response);
                return;
            }
#pragma warning restore 162

            using (Bitmap originalImage = (Bitmap)Bitmap.FromFile(imageFile, false))
            {
                int originalWidth = originalImage.Width;
                int originalHeight = originalImage.Height;
                int width = 0;
                int height = 0;
                if (size > 0 && originalWidth >= originalHeight && originalWidth > size)
                {
                    width = size;
                    height = Convert.ToInt32((double)size * (double)originalHeight / (double)originalWidth);
                }
                else if (size > 0 && originalHeight >= originalWidth && originalHeight > size)
                {
                    width = Convert.ToInt32((double)size * (double)originalWidth / (double)originalHeight);
                    height = size;
                }
                else
                {
                    width = originalWidth;
                    height = originalHeight;
                }
                using (Bitmap newImage = new Bitmap(width, height))
                {
                    using (Graphics target = Graphics.FromImage(newImage))
                    {
                        target.CompositingQuality = CompositingQuality.HighSpeed;
                        target.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        target.CompositingMode = CompositingMode.SourceCopy;
                        CreateNewImage(originalImage, size, false, target, 0);

                        WritePngImage(newImage, response);

#pragma warning disable 162
                        if (Caching == CacheLocation.Disk)
                        {
                            File.WriteAllBytes(buildPath, GetImageBytes(newImage));
                        }
#pragma warning restore 162
                    }
                }
            }
        }

        /// <summary>
        /// Generate a sprite strip response
        /// </summary>
        /// <param name="dir">The directory</param>
        /// <param name="size">The size in pixels of a bounding square around the reduced image.</param>
        /// <param name="response">The HttpResponse to output to.</param>
        public static void GenerateSpriteStripResponse(string dir, int size, HttpResponse response)
        {
            ClientCache(response);
            string buildPath = null;

            if (File.Exists(dir))
            {
                dir = Path.GetDirectoryName(dir);
            }
#pragma warning disable 162
            switch (Caching)
            {
                case CacheLocation.Disk:
                    if (GetCachedPathAndCheckCacheStatus(dir, out buildPath))
                    {
                        WriteImage(buildPath, response);
                        return;
                    }
                    break;
                case CacheLocation.Memory:
                    buildPath = dir.Replace('\\', '_').Replace(':', '_');
                    byte[] cachedBytes = (byte[])HttpRuntime.Cache.Get(buildPath);

                    if (cachedBytes != null)
                    {
                        WritePngImage(cachedBytes, response);
                        return;
                    }
                    break;
            }
#pragma warning restore 162

            // Generate strip
            DirectoryInfo[] subDirectories = GetSubDirectories(dir);
            FileInfo[] files = GetImages(dir);
            int width = (size + 1) * (subDirectories.Length + files.Length + 1);
            int height = size;
            using (Bitmap newImage = new Bitmap(width, height))
            {
                using (Graphics g = Graphics.FromImage(newImage))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.FillRectangle(new SolidBrush(BackGround), 0, 0, width, height);

                    int i = 0;
                    CreateFolderImage(true, dir, size, g, i++);
                    foreach (DirectoryInfo subdir in subDirectories)
                    {
                        CreateFolderImage(false, subdir.FullName, size, g, i++);
                    }
                    foreach (FileInfo file in files)
                    {
                        using (Bitmap originalImage = (Bitmap)Bitmap.FromFile(file.FullName, false))
                        {
                            CreateNewImage(originalImage, size, true, g, i++);
                        }
                    }
                }
                WriteJpegImage(newImage, response);

#pragma warning disable 162
                switch (Caching)
                {
                    case CacheLocation.Disk:
                        File.WriteAllBytes(buildPath, GetImageBytes(newImage));
                        break;
                    case CacheLocation.Memory:
                        HttpRuntime.Cache.Insert(buildPath, GetImageBytes(newImage),
                            new CacheDependency(dir), DateTime.MaxValue, TimeSpan.FromMinutes(MemoryCacheSlidingDuration));
                        break;
                }
#pragma warning restore 162
            }
        }

        /// <summary>
        /// Prepares a string to be used in JScript by escaping characters.
        /// </summary>
        /// <remarks>This is not a general purpose escaping function:
        /// we do not encode characters that can't be in Windows paths.
        /// It should not be used in general to prevent injection attacks.</remarks>
        /// <param name="unencoded">The unencoded string.</param>
        /// <returns>The encoded string.</returns>
        public static string JScriptEncode(string unencoded)
        {
            System.Text.StringBuilder sb = null;
            int checkedIndex = 0;
            int len = unencoded.Length;
            for (int i = 0; i < len; i++)
            {
                char c = unencoded[i];
                if ((c == '\'') || (c == '\"'))
                {
                    if (sb == null)
                    {
                        sb = new System.Text.StringBuilder(len + 1);
                    }
                    sb.Append(unencoded.Substring(checkedIndex, i - checkedIndex));
                    sb.Append('\\');
                    sb.Append(unencoded[i]);
                    checkedIndex = i + 1;
                }
            }
            if (sb == null)
            {
                return unencoded;
            }
            if (checkedIndex < len)
            {
                sb.Append(unencoded.Substring(checkedIndex));
            }
            return sb.ToString();
        }

        /// <summary>
        /// Creates a reduced Bitmap from a full-size Bitmap.
        /// </summary>
        /// <param name="originalImage">The full-size bitmap to reduce.</param>
        /// <param name="size">The size in pixels of a square bounding the reduced bitmap.</param>
        /// <param name="thumbnail">True if the reduced image is a thumbnail.</param>
        /// <param name="target">The graphics where to draw the reduced image.</param>
        /// <param name="index">The index of the reduced bitmap in the target bitmap.</param>
        static void CreateNewImage(Bitmap originalImage, int size, bool thumbnail, Graphics target, int index)
        {
            int originalWidth = originalImage.Width;
            int originalHeight = originalImage.Height;
            int targetOffset = thumbnail ? index * (size + 1) : 0;
            int width, height;
            int drawXOffset, drawYOffset, drawWidth, drawHeight;

            if (size > 0 && originalWidth >= originalHeight && originalWidth > size)
            {
                width = size;
                height = Convert.ToInt32((double)size * (double)originalHeight / (double)originalWidth);
            }
            else if (size > 0 && originalHeight >= originalWidth && originalHeight > size)
            {
                width = Convert.ToInt32((double)size * (double)originalWidth / (double)originalHeight);
                height = size;
            }
            else
            {
                width = originalWidth;
                height = originalHeight;
            }

            drawXOffset = 0;
            drawYOffset = 0;
            drawWidth = width;
            drawHeight = height;

            if (thumbnail)
            {
                width = Math.Max(width, size);
                height = Math.Max(height, size);
                drawXOffset = (width - drawWidth) / 2;
                drawYOffset = (height - drawHeight) / 2;
            }

            float borderWidth = thumbnail ? ThumbnailBorderWidth : PreviewBorderWidth;
            Pen BorderPen = new Pen(BorderColor);
            BorderPen.Width = borderWidth;
            BorderPen.LineJoin = LineJoin.Round;
            BorderPen.StartCap = LineCap.Round;
            BorderPen.EndCap = LineCap.Round;
            target.DrawRectangle(BorderPen,
                drawXOffset + borderWidth / 2 + targetOffset,
                drawYOffset + borderWidth / 2,
                drawWidth - borderWidth,
                drawHeight - borderWidth);

            target.DrawImage(originalImage,
                drawXOffset + borderWidth + targetOffset,
                drawYOffset + borderWidth,
                drawWidth - 2 * borderWidth,
                drawHeight - 2 * borderWidth);
        }

        /// <summary>
        /// Creates the thumbnail Bitmap for a folder.
        /// </summary>
        /// <param name="isParentFolder">True if the up arrow must be drawn.</param>
        /// <param name="folder">The path of the folder.</param>
        /// <param name="size">The size in pixels of a square bounding the thumbnail.</param>
        /// <param name="target">The graphic object where to draw the reduced image.</param>
        /// <param name="index">The index of the reduced bitmap in the target bitmap.</param>
        static void CreateFolderImage(bool isParentFolder, string folder, int size, Graphics target, int index)
        {
            float targetOffset = (float)(index * (size + 1));
            Random rnd = new Random();
            List<string> imagesToDraw = new List<string>();
            int nbFound;
            SearchOption searchOption = isParentFolder ? SearchOption.TopDirectoryOnly : SearchOption.AllDirectories;
            string[] images = Directory.GetFiles(folder, "default.jpg", searchOption);
            for (nbFound = 0; nbFound < Math.Min(UpFolderStackHeight, images.Length); nbFound++)
            {
                imagesToDraw.Add(images[nbFound]);
            }
            if (nbFound < UpFolderStackHeight)
            {
                images = Directory.GetFiles(folder, "*.jpg", searchOption);
                for (int i = 0; i < Math.Min(UpFolderStackHeight - nbFound, images.Length); i++)
                {
                    imagesToDraw.Insert(0, images[rnd.Next(images.Length)]);
                }
            }
            float drawXOffset = size / 2;
            float drawYOffset = size / 2;
            double angleAmplitude = Math.PI / 10;
            int imageFolderSize = (int)(size / (Math.Cos(angleAmplitude) + Math.Sin(angleAmplitude)));

            foreach (string folderImagePath in imagesToDraw)
            {
                Bitmap folderImage = new Bitmap(folderImagePath);

                int width = folderImage.Width;
                int height = folderImage.Height;
                if (imageFolderSize > 0 && folderImage.Width >= folderImage.Height && folderImage.Width > imageFolderSize)
                {
                    width = imageFolderSize;
                    height = imageFolderSize * folderImage.Height / folderImage.Width;
                }
                else if (imageFolderSize > 0 && folderImage.Height >= folderImage.Width && folderImage.Height > imageFolderSize)
                {
                    width = imageFolderSize * folderImage.Width / folderImage.Height;
                    height = imageFolderSize;
                }

                Pen UpFolderBorderPen = new Pen(new SolidBrush(UpFolderBorderColor), UpFolderBorderWidth);
                UpFolderBorderPen.LineJoin = LineJoin.Round;
                UpFolderBorderPen.StartCap = LineCap.Round;
                UpFolderBorderPen.EndCap = LineCap.Round;

                double angle = (0.5 - rnd.NextDouble()) * angleAmplitude;
                float sin = (float)Math.Sin(angle);
                float cos = (float)Math.Cos(angle);
                float sh = sin * height / 2;
                float ch = cos * height / 2;
                float sw = sin * width / 2;
                float cw = cos * width / 2;
                float shb = sin * (height + UpFolderBorderPen.Width) / 2;
                float chb = cos * (height + UpFolderBorderPen.Width) / 2;
                float swb = sin * (width + UpFolderBorderPen.Width) / 2;
                float cwb = cos * (width + UpFolderBorderPen.Width) / 2;

                target.DrawPolygon(UpFolderBorderPen, new PointF[] {
                new PointF(
                    drawXOffset - cwb - shb + targetOffset,
                    drawYOffset + chb - swb),
                new PointF(
                    drawXOffset - cwb + shb + targetOffset,
                    drawYOffset - swb - chb),
                new PointF(
                    drawXOffset + cwb + shb + targetOffset,
                    drawYOffset + swb - chb),
                new PointF(
                    drawXOffset + cwb - shb + targetOffset,
                    drawYOffset + swb + chb)
            });

                target.DrawImage(folderImage, new PointF[] {
                new PointF(
                    drawXOffset - cw + sh + targetOffset,
                    drawYOffset - sw - ch),
                new PointF(
                    drawXOffset + cw + sh + targetOffset,
                    drawYOffset + sw - ch),
                new PointF(
                    drawXOffset - cw - sh + targetOffset,
                    drawYOffset + ch - sw)
            });
                folderImage.Dispose();
            }

            if (isParentFolder)
            {
                Pen UpArrowPen = new Pen(new SolidBrush(UpArrowColor), UpArrowWidth);
                UpArrowPen.LineJoin = LineJoin.Round;
                UpArrowPen.StartCap = LineCap.Flat;
                UpArrowPen.EndCap = LineCap.Round;

                target.DrawLines(UpArrowPen, new PointF[] {
                new PointF(drawXOffset - UpArrowSize * size + targetOffset, drawYOffset + UpArrowSize * size),
                new PointF(drawXOffset + UpArrowSize * size + targetOffset, drawYOffset + UpArrowSize * size),
                new PointF(drawXOffset + UpArrowSize * size + targetOffset, drawYOffset - UpArrowSize * size),
                new PointF(drawXOffset + UpArrowSize * size * 2 / 3 + targetOffset, drawYOffset - UpArrowSize * size * 2 / 3),
                new PointF(drawXOffset + UpArrowSize * size + targetOffset, drawYOffset - UpArrowSize * size),
                new PointF(drawXOffset + UpArrowSize * size * 4 / 3 + targetOffset, drawYOffset - UpArrowSize * size * 2 / 3)
            });
            }
        }

        /// <summary>
        /// Extracts and caches the metadata for an image.
        /// </summary>
        /// <param name="pictureFileInfo">The FileInfo to the image.</param>
        /// <returns>The MetaData for the image.</returns>
        public static Metadata GetImageData(FileInfo pictureFileInfo)
        {
            string cacheKey = "data(" + pictureFileInfo.FullName + ")";
            Cache cache = HttpContext.Current.Cache;
            object cached = cache[cacheKey];
            // The following line deals with recompilations of the handlers
            // which may otherwise result in the cached type being different
            // from the one the handler uses.
            if (cached == null || cached.GetType() != typeof(Metadata))
            {
                Metadata data = new Metadata();
                ExifReader exif = new ExifReader(pictureFileInfo);
                exif.Extract(data);
                IptcReader iptc = new IptcReader(pictureFileInfo);
                iptc.Extract(data);
                JpegReader jpeg = new JpegReader(pictureFileInfo);
                jpeg.Extract(data);
                cache.Insert(cacheKey, data, new CacheDependency(pictureFileInfo.FullName));
                return data;
            }
            return (Metadata)cached;
        }

        /// <summary>
        /// Gets and caches the most relevant date available for an image.
        /// It looks first at the EXIF date, then at the creation date from ITPC data,
        /// and then at the file's creation date if everything else failed.
        /// </summary>
        /// <param name="pictureFileInfo">The FileInfo for the image.</param>
        /// <returns>The date.</returns>
        public static DateTime GetImageDate(FileInfo pictureFileInfo)
        {
            string cacheKey = "date(" + pictureFileInfo.FullName + ")";
            Cache cache = HttpContext.Current.Cache;
            DateTime result = DateTime.MinValue;
            object cached = cache[cacheKey];
            if (cached == null)
            {
                Metadata data = ImageHelper.GetImageData(pictureFileInfo);
                ExifDirectory directory = (ExifDirectory)data.GetDirectory(typeof(ExifDirectory));
                if (directory.ContainsTag(ExifDirectory.TAG_DATETIME))
                {
                    try
                    {
                        result = directory.GetDate(ExifDirectory.TAG_DATETIME);
                    }
                    catch { }
                }
                else
                {
                    IptcDirectory iptcDir = (IptcDirectory)data.GetDirectory(typeof(IptcDirectory));
                    if (iptcDir.ContainsTag(IptcDirectory.TAG_DATE_CREATED))
                    {
                        try
                        {
                            result = iptcDir.GetDate(IptcDirectory.TAG_DATE_CREATED);
                        }
                        catch { }
                    }
                    else
                    {
                        result = pictureFileInfo.CreationTime;
                    }
                }
                cache.Insert(cacheKey, result, new CacheDependency(pictureFileInfo.FullName));
            }
            else
            {
                result = (DateTime)cached;
            }
            return result;
        }

        /// <summary>
        /// Gets the list of subfolders under the specified path,
        /// excluding some insignificant system directories and
        /// sorted by name.
        /// </summary>
        /// <param name="path">The parent path to explore.</param>
        /// <returns>The list of subdirectories.</returns>
        public static DirectoryInfo[] GetSubDirectories(string path)
        {
            string[] dirs = Directory.GetDirectories(path);
            List<DirectoryInfo> results = null;
            if (dirs != null && dirs.Length > 0)
            {
                results = new List<DirectoryInfo>(dirs.Length);
                foreach (string d in dirs)
                {
                    string dir = System.IO.Path.GetFileName(d).ToLower(CultureInfo.InvariantCulture);
                    if (dir.StartsWith("_vti_") ||
                        dir.StartsWith("app_") ||
                        (dir == "_albumcache") ||
                        (dir[0] == '{') ||
                        (dir == "bin") ||
                        (dir == "aspnet_client"))
                    {
                        continue;
                    }
                    results.Add(new DirectoryInfo(d));
                }
            }
            if (results == null) return new DirectoryInfo[] { };
            results.Sort(delegate (DirectoryInfo a, DirectoryInfo b)
            {
                return String.Compare(a.Name, b.Name, StringComparison.InvariantCultureIgnoreCase);
            });
            return results.ToArray();
        }

        /// <summary>
        /// Gets an array of file infos for the images in a folder, sorted by date.
        /// </summary>
        /// <param name="path">The folder's physical path.</param>
        /// <returns>The list of file infos, sorted by date.</returns>
        public static FileInfo[] GetImages(string path)
        {
            return GetImages(path, false);
        }

        /// <summary>
        /// Gets an array of file infos for the images in a folder, sorted by date.
        /// </summary>
        /// <param name="path">The folder's physical path.</param>
        /// <param name="includesubFolders">True if subfolders should be included.</param>
        /// <returns>The list of file infos, sorted by date.</returns>
        public static FileInfo[] GetImages(string path, bool includesubFolders)
        {
            DirectoryInfo di = new DirectoryInfo(path);
            FileInfo[] pics = di.GetFiles("*.jpg",
                includesubFolders ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly);
            Array.Sort<FileInfo>(pics, delegate (FileInfo x, FileInfo y)
            {
                return GetImageDate(x).CompareTo(GetImageDate(y));
            });
            return pics;
        }

        /// <summary>
        /// A better UrlEncode that also encodes quotes.
        /// </summary>
        /// <param name="urlFragment">The URL fragment to encode.</param>
        /// <returns>The encoded URL fragment.</returns>
        public static string UrlEncode(string urlFragment)
        {
            return HttpUtility.UrlEncode(urlFragment).Replace(@"'", "%27");
        }

        private static ImageCodecInfo _jpegCodec;
        private static ImageCodecInfo _pngCodec;
        private static object _codecLock = new object();
        /// <summary>
        /// Gets the JPEG codec.
        /// </summary>
        /// <returns>The JPEG codec.</returns>
        static ImageCodecInfo GetJpegCodec()
        {
            if (_jpegCodec != null) return _jpegCodec;
            lock (_codecLock)
            {
                ImageCodecInfo[] encoders = ImageCodecInfo.GetImageEncoders();

                foreach (ImageCodecInfo e in encoders)
                {
                    if (e.MimeType == "image/jpeg")
                    {
                        _jpegCodec = e;
                        return e;
                    }
                }
            }
            return null;
        }

        /// <summary>
        /// Gets the PNG codec.
        /// </summary>
        /// <returns>The PNG codec.</returns>
        static ImageCodecInfo GetPngCodec()
        {
            if (_pngCodec != null) return _pngCodec;
            lock (_codecLock)
            {
                ImageCodecInfo[] encoders = ImageCodecInfo.GetImageEncoders();

                foreach (ImageCodecInfo e in encoders)
                {
                    if (e.MimeType == "image/png")
                    {
                        _pngCodec = e;
                        return e;
                    }
                }
            }
            return null;
        }

        /// <summary>
        /// Returns the encoder parameters.
        /// </summary>
        /// <returns></returns>
        static EncoderParameters GetJpgEncoderParams()
        {
            EncoderParameters encoderParams = new EncoderParameters();
            encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, ThumbnailJpegQuality);
            return encoderParams;
        }

        /// <summary>
        /// Writes a JPEG image on the response.
        /// </summary>
        /// <param name="image">The Bitmap to write.</param>
        /// <param name="response">The HttpResponse to write to.</param>
        static void WriteJpegImage(Bitmap image, HttpResponse response)
        {
            ImageCodecInfo codec = GetJpegCodec();
            EncoderParameters encoderParams = GetJpgEncoderParams();

            response.ContentType = "image/jpeg";
            image.Save(response.OutputStream, codec, encoderParams);

            encoderParams.Dispose();
        }

        /// <summary>
        /// Writes a PNG image on the response.
        /// </summary>
        /// <param name="image">The Bitmap to write.</param>
        /// <param name="response">The HttpResponse to write to.</param>
        static void WritePngImage(Bitmap image, HttpResponse response)
        {
            ImageCodecInfo codec = GetPngCodec();

            response.ContentType = "image/png";
            using (MemoryStream memoryStream = new MemoryStream())
            {
                image.Save(memoryStream, ImageFormat.Png);
                memoryStream.WriteTo(response.OutputStream);
            }
        }

        /// <summary>
        /// Writes an image to the response.
        /// </summary>
        /// <param name="path">The path of the file.</param>
        /// <param name="response">The HttpResponse to write to.</param>
        static void WriteImage(string path, HttpResponse response)
        {
            response.ContentType =
                String.Equals(Path.GetExtension(path), ".png", StringComparison.OrdinalIgnoreCase) ?
                "image/png" : "image/jpeg";
            response.TransmitFile(path);
        }

        /// <summary>
        /// Writes a byte array to the response as a PNG.
        /// </summary>
        /// <param name="imageBytes">The bytes to write</param>
        /// <param name="response">The HttpResponse to write to.</param>
        static void WritePngImage(byte[] imageBytes, HttpResponse response)
        {
            response.ContentType = "image/png";
            response.OutputStream.Write(imageBytes, 0, imageBytes.Length);
        }

        /// <summary>
        /// Writes a byte array to the response as a JPG.
        /// </summary>
        /// <param name="imageBytes">The bytes to write</param>
        /// <param name="response">The HttpResponse to write to.</param>
        static void WriteJpgImage(byte[] imageBytes, HttpResponse response)
        {
            response.ContentType = "image/jpeg";
            response.OutputStream.Write(imageBytes, 0, imageBytes.Length);
        }

        /// <summary>
        /// Gets an array of bytes from a Bitmap.
        /// </summary>
        /// <param name="image">The Bitmap.</param>
        /// <returns>The byte array.</returns>
        static byte[] GetImageBytes(Bitmap image)
        {
            ImageCodecInfo codec = GetJpegCodec();
            EncoderParameters encoderParams = GetJpgEncoderParams();

            MemoryStream ms = new MemoryStream();
            image.Save(ms, codec, encoderParams);
            ms.Close();

            encoderParams.Dispose();
            return ms.ToArray();
        }
    }

    /// <summary>
    /// The display modes or views for the Album Handler.
    /// </summary>
    public enum AlbumHandlerMode
    {
        /// <summary>
        /// Unknown mode.
        /// </summary>
        Unknown = 0,
        /// <summary>
        /// Displays the contents of a folder.
        /// </summary>
        Folder = 1,
        /// <summary>
        /// Displays the preview page for an image.
        /// </summary>
        Page = 2,
        /// <summary>
        /// Returns the reduced image used in the preview page.
        /// </summary>
        Preview = 3,
        /// <summary>
        /// Returns an image thumbnail.
        /// </summary>
        Thumbnail = 4,
        /// <summary>
        /// Returns the CSS stylesheet.
        /// </summary>
        Css = 5,
        /// <summary>
        /// Renders a transparent image.
        /// </summary>
        Blank = 6
    }

    /// <summary>
    /// Storing location for the cached preview and thumbnail images.
    /// </summary>
    public enum CacheLocation
    {
        /// <summary>
        /// Cached images are stored on disk in the application's compilation folder.
        /// </summary>
        Disk,
        /// <summary>
        /// Images are cached in memory.
        /// </summary>
        Memory,
        /// <summary>
        /// No caching. Images are redrawn on every request.
        /// </summary>
        None
    }

    /// <summary>
    /// Navigation mode when the album is used as a control.
    /// </summary>
    public enum NavigationMode
    {
        /// <summary>
        /// This mode uses callbacks to refresh the album
        /// without navigating away from the page or posting back.
        /// Ifthe browser does not support callbacks, the control will post back.
        /// </summary>
        Callback,
        /// <summary>
        /// This mode uses form post backs to navigate in the album.
        /// </summary>
        Postback,
        /// <summary>
        /// Uses regular links to navigate in the album.
        /// May have side-effects on the rest of the page,
        /// which may have its own state management.
        /// </summary>
        Link
    }

    /// <summary>
    /// A template container for the album handler.
    /// </summary>
    public sealed class AlbumTemplateContainer : Control, INamingContainer, IDataItemContainer
    {
        private Album _owner;

        /// <summary>
        /// Constructs a template container for an Album.
        /// </summary>
        /// <param name="owner">The Album that owns this template.</param>
        public AlbumTemplateContainer(Album owner)
        {
            _owner = owner;
        }

        /// <summary>
        /// The Album that owns this template.
        /// </summary>
        public Album Owner
        {
            get
            {
                return _owner;
            }
        }

        /// <summary>
        /// The DataItem is the owner Album.
        /// </summary>
        object IDataItemContainer.DataItem
        {
            get { return Owner; }
        }

        /// <summary>
        /// The templates are single items, so the index is always zero.
        /// </summary>
        int IDataItemContainer.DataItemIndex
        {
            get { return 0; }
        }

        /// <summary>
        /// The templates are single items, so the index is always zero.
        /// </summary>
        int IDataItemContainer.DisplayIndex
        {
            get { return 0; }
        }
    }

    /// <summary>
    /// Base for classes that describe an album page
    /// </summary>
    public abstract class AlbumPageInfo
    {
        private Album _owner;
        private string _path;

        private string _link;
        private string _permalink;

        /// <summary>
        /// Constructs an AlbumPageInfo.
        /// </summary>
        /// <param name="owner">The Album that owns this info.</param>
        /// <param name="path">The virtual path of the page.</param>
        public AlbumPageInfo(Album owner, string path)
        {
            _owner = owner;
            _path = path;
        }

        /// <summary>
        /// The Album that owns this page.
        /// </summary>
        public Album Owner
        {
            get
            {
                return _owner;
            }
        }

        /// <summary>
        /// The virtual path to the page.
        /// </summary>
        public string Path
        {
            get
            {
                return _path;
            }
        }

        /// <summary>
        /// The character used as a command for this type of album page
        /// </summary>
        protected abstract char CommandCharacter { get; }

        /// <summary>
        /// The AlbumHandlerMode for this type of pages
        /// </summary>
        protected abstract AlbumHandlerMode AlbumMode { get; }

        /// <summary>
        /// A javascript link (callback if the browser supports it, postback otherwise) to this album page.
        /// </summary>
        public string Link
        {
            get
            {
                if (_link == null)
                {
                    if (!_owner.IsControl || _owner.NavigationMode == NavigationMode.Link)
                    {
                        _link = PermaLink;
                    }
                    else
                    {
                        string dirPrefix = _owner.PathPrefix;
                        string arg = CommandCharacter + _path;
                        if (_owner.NavigationMode == NavigationMode.Callback &&
                            HttpContext.Current.Request.Browser.SupportsCallback)
                        {

                            _owner.Page.ClientScript.RegisterForEventValidation(_owner.UniqueID, arg);
                            _link = "javascript:" + _owner.Page.ClientScript.GetCallbackEventReference(
                                _owner,
                                '\'' + ImageHelper.JScriptEncode(arg) + '\'',
                                Album.CallbackFunction,
                                '\'' + _owner.ClientID + '\'', false);
                        }
                        else
                        {
                            _link = _owner.Page.ClientScript.GetPostBackClientHyperlink(_owner, arg, true);
                        }
                    }
                }
                return _link;
            }
        }

        /// <summary>
        /// A permanent link to this image's preview page.
        /// </summary>
        public string PermaLink
        {
            get
            {
                if (_permalink == null)
                {
                    _permalink = ((_owner.Page != null) ?
                        _owner.ResolveClientUrl(_owner.Page.AppRelativeVirtualPath) :
                        String.Empty) +
                        "?albummode=" + AlbumMode + "&albumpath=" + ImageHelper.UrlEncode(_path);
                }
                return _permalink;
            }
        }
    }

    /// <summary>
    /// Describes an album folder.
    /// </summary>
    public sealed class AlbumFolderInfo : AlbumPageInfo
    {
        private bool _isParent;

        private string _name;

        /// <summary>
        /// Constructs an AlbumFolderInfo.
        /// </summary>
        /// <param name="owner">The Album that owns this info.</param>
        /// <param name="path">The virtual path of the folder.</param>
        /// <param name="isParent">True if the folder decribes the parent of the current Album view.</param>
        public AlbumFolderInfo(Album owner, string path, bool isParent)
            : this(owner, path)
        {
            _isParent = isParent;
        }

        /// <summary>
        /// Constructs an AlbumFolderInfo.
        /// </summary>
        /// <param name="owner">The Album that owns this info.</param>
        /// <param name="path">The virtual path of the folder.</param>
        public AlbumFolderInfo(Album owner, string path)
            : base(owner, path) { }

        protected override char CommandCharacter
        {
            get
            {
                return Album.FolderCommand;
            }
        }

        protected override AlbumHandlerMode AlbumMode
        {
            get
            {
                return AlbumHandlerMode.Folder;
            }
        }

        /// <summary>
        /// The icon URL for the folder.
        /// </summary>
        public string IconUrl
        {
            get
            {
                return Owner.FilePath +
                    "?albummode=thumbnail&albumpath=" +
                    ImageHelper.UrlEncode(Path);
            }
        }

        /// <summary>
        /// True if the folder is the parent of the current view.
        /// </summary>
        public bool IsParent
        {
            get
            {
                return _isParent;
            }
        }

        /// <summary>
        /// The name of this folder.
        /// </summary>
        public string Name
        {
            get
            {
                if (_name == null)
                {
                    _name = Path.Substring(Path.LastIndexOf('/') + 1);
                }
                return _name;
            }
        }
    }

    /// <summary>
    /// Describes an Album image.
    /// </summary>
    public sealed class ImageInfo : AlbumPageInfo
    {
        private readonly string _physicalPath;
        private string _name;
        private readonly int _index;

        /// <summary>
        /// Constructs an ImageInfo.
        /// </summary>
        /// <param name="owner">The Album that owns this image.</param>
        /// <param name="path">The virtual path of the image.</param>
        /// <param name="physicalPath">The physical path of the image.</param>
        /// <param name="index">The index of the image in the thumbnail strip. -1 if not in the strip.</param>
        public ImageInfo(Album owner, string path, string physicalPath, int index)
            : base(owner, path)
        {
            _physicalPath = physicalPath;
            _index = index;
        }

        protected override char CommandCharacter
        {
            get
            {
                return Album.PageCommand;
            }
        }

        protected override AlbumHandlerMode AlbumMode
        {
            get
            {
                return AlbumHandlerMode.Page;
            }
        }

        /// <summary>
        /// The image caption.
        /// It is the name if available from the ITPC meta-data, or the file name.
        /// </summary>
        public string Caption
        {
            get
            {
                if (_name == null)
                {
                    FileInfo pictureFileInfo = new FileInfo(_physicalPath);
                    Metadata data = ImageHelper.GetImageData(pictureFileInfo);
                    IptcDirectory iptcDir = (IptcDirectory)data.GetDirectory(typeof(IptcDirectory));
                    if (iptcDir.ContainsTag(IptcDirectory.TAG_OBJECT_NAME))
                    {
                        _name = iptcDir.GetString(IptcDirectory.TAG_OBJECT_NAME);
                    }
                    else
                    {
                        _name = System.IO.Path.GetFileNameWithoutExtension(_physicalPath);
                    }
                }
                return _name;
            }
        }

        /// <summary>
        /// The date the image was created.
        /// </summary>
        public DateTime Date
        {
            get
            {
                return ImageHelper.GetImageDate(new FileInfo(_physicalPath));
            }
        }

        /// <summary>
        /// The URL of the thumbnail for this image.
        /// </summary>
        public string IconUrl
        {
            get
            {
                return Owner.FilePath +
                    "?albummode=thumbnail&albumpath=" +
                    ImageHelper.UrlEncode(System.IO.Path.GetDirectoryName(Path));
            }
        }

        /// <summary>
        /// The index of the image in the thumbnail strip, -1 if not on the strip.
        /// </summary>
        public int Index
        {
            get
            {
                return _index;
            }
        }

        /// <summary>
        /// The metadata for this image.
        /// </summary>
        public Dictionary<string, List<KeyValuePair<string, string>>> MetaData
        {
            get
            {
                Metadata data = ImageHelper.GetImageData(new FileInfo(_physicalPath));
                Dictionary<string, List<KeyValuePair<string, string>>> dict =
                    new Dictionary<string, List<KeyValuePair<string, string>>>(data.GetDirectoryCount());
                IEnumerator dirs = data.GetDirectoryIterator();
                while (dirs.MoveNext())
                {
                    MetadataDirectory dir = (MetadataDirectory)dirs.Current;
                    List<KeyValuePair<string, string>> properties =
                        new List<KeyValuePair<string, string>>(dir.GetTagCount());
                    dict.Add(dir.GetName(), properties);
                    IEnumerator tags = dir.GetTagIterator();
                    while (tags.MoveNext())
                    {
                        string name = String.Empty;
                        string description = String.Empty;
                        try
                        {
                            Tag tag = (Tag)tags.Current;
                            name = tag.GetTagName();
                            description = tag.GetDescription();
                        }
                        catch { }
                        if (!String.IsNullOrEmpty(description) &&
                            !String.IsNullOrEmpty(name) &&
                            !name.StartsWith("Unknown ") &&
                            !name.StartsWith("Makernote Unknown ") &&
                            !description.StartsWith("Unknown (\""))
                        {

                            properties.Add(new KeyValuePair<string, string>(name, description));
                        }
                    }
                }
                return dict;
            }
        }

        /// <summary>
        /// The URL of the preview image for this image.
        /// </summary>
        public string PreviewUrl
        {
            get
            {
                return Owner.FilePath +
                    "?albummode=preview&albumpath=" +
                    ImageHelper.UrlEncode(Path);
            }
        }

        /// <summary>
        /// The virtual path of the full resolution image.
        /// </summary>
        public string Url
        {
            get
            {
                return Path;
            }
        }
    }

    /// <summary>
    /// The photo album handler.
    /// This class can act as an HttpHandler or as a Control.
    /// </summary>
    public sealed class Album : UserControl, IHttpHandler, IPostBackEventHandler, ICallbackEventHandler
    {
        private const string AlbumScript = @"
function photoAlbumDetails(id) {
    var details = document.getElementById(id + '_details');
    if (details.style.display && details.style.display == 'none') {
        details.style.display = 'block';
    }
    else {
        details.style.display = 'none';
    }
}
";

        private const string CallbackScript = @"
function photoAlbumCallback(result, context) {
    var album = document.getElementById(context);
    if (album) {
        album.innerHTML = result;
    }
}
";

        internal const string CallbackFunction = "photoAlbumCallback";

        internal const char FolderCommand = 'f';
        internal const char PageCommand = 'p';

        private HttpRequest _request;
        private HttpResponse _response;

        private string _requestPathPrefix;
        private string _requestDir;

        private AlbumHandlerMode _mode;
        private bool _isControl;
        private string _filePath;
        private string _rawPath;
        private string _physicalPath;
        private string _title;
        private string _description;

        private ITemplate _folderModeTemplate;
        private ITemplate _pageModeTemplate;

        private ImageInfo _image;
        private AlbumFolderInfo _parentFolder;
        private ImageInfo _previousImage;
        private ImageInfo _nextImage;

        /// <summary>
        /// The tooltip for going back to the folder view from the image preview.
        /// </summary>
        [Localizable(true), DefaultValue("Go back to folder view")]
        public string BackToFolderViewTooltip
        {
            get
            {
                string s = ViewState["BackToFolderViewTooltip"] as string;
                return (s == null) ? "Go back to folder view" : s;
            }
            set
            {
                ViewState["BackToFolderViewTooltip"] = value;
            }
        }

        /// <summary>
        /// The text of the back to parent link.
        /// </summary>
        [Localizable(true), DefaultValue("Up")]
        public string BackToParentText
        {
            get
            {
                string s = ViewState["BackToParentText"] as string;
                return (s == null) ? "Up" : s;
            }
            set
            {
                ViewState["BackToParentText"] = value;
            }
        }

        /// <summary>
        /// Tooltip for going back to the parent folder.
        /// </summary>
        [Localizable(true), DefaultValue("Click to go back to the parent folder")]
        public string BackToParentTooltip
        {
            get
            {
                string s = ViewState["BackToParentTooltip"] as string;
                return (s == null) ? "Click to go back to the parent folder" : s;
            }
            set
            {
                ViewState["BackToParentTooltip"] = value;
            }
        }

        /// <summary>
        /// The top CSS class for the control.
        /// </summary>
        [DefaultValue("album")]
        public string CssClass
        {
            get
            {
                string s = ViewState["CssClass"] as string;
                return (s == null) ? "album" : s;
            }
            set
            {
                ViewState["CssClass"] = value;
            }
        }

        /// <summary>
        /// The CSS class for the details (meta-data) section in the preview pages.
        /// </summary>
        [DefaultValue("albumDetails")]
        public string DetailsCssClass
        {
            get
            {
                string s = ViewState["DetailsCssClass"] as string;
                return (s == null) ? "albumDetails" : s;
            }
            set
            {
                ViewState["DetailsCssClass"] = value;
            }
        }

        /// <summary>
        /// The CSS class for the details (meta-data) link in the preview pages.
        /// </summary>
        [DefaultValue("albumDetailsLink")]
        public string DetailsLinkCssClass
        {
            get
            {
                string s = ViewState["DetailsLinkCssClass"] as string;
                return (s == null) ? "albumDetailsLink" : s;
            }
            set
            {
                ViewState["DetailsLinkCssClass"] = value;
            }
        }

        /// <summary>
        /// The text for the details (meta-data) link in the preview pages.
        /// </summary>
        [Localizable(true), DefaultValue("Details")]
        public string DetailsText
        {
            get
            {
                string s = ViewState["DetailsText"] as string;
                return (s == null) ? "Details" : s;
            }
            set
            {
                ViewState["DetailsText"] = value;
            }
        }

        /// <summary>
        /// The tooltip for displaying the preview page.
        /// </summary>
        [Localizable(true), DefaultValue("Click to display")]
        public string DisplayImageTooltip
        {
            get
            {
                string s = ViewState["DisplayImageTooltip"] as string;
                return (s == null) ? "Click to display" : s;
            }
            set
            {
                ViewState["DisplayImageTooltip"] = value;
            }
        }

        /// <summary>
        /// Tooltip for seeing the image at full resolution.
        /// </summary>
        [Localizable(true), DefaultValue("Click to view picture at full resolution")]
        public string DisplayFullResolutionTooltip
        {
            get
            {
                string s = ViewState["DisplayFullResolutionTooltip"] as string;
                return (s == null) ? "Click to view picture at full resolution" : s;
            }
            set
            {
                ViewState["DisplayFullResolutionTooltip"] = value;
            }
        }

        /// <summary>
        /// The path of the current file.
        /// </summary>
        internal string FilePath
        {
            get
            {
                return _filePath;
            }
        }

        /// <summary>
        /// The template for the folder mode.
        /// </summary>
        [PersistenceMode(PersistenceMode.InnerProperty), TemplateContainer(typeof(AlbumTemplateContainer))]
        public ITemplate FolderModeTemplate
        {
            get
            {
                return _folderModeTemplate;
            }
            set
            {
                _folderModeTemplate = value;
            }
        }

        /// <summary>
        /// The URL of the handler.
        /// </summary>
        [DefaultValue("~/album.ashx"), UrlProperty]
        public string HandlerUrl
        {
            get
            {
                string s = ViewState["HandlerUrl"] as string;
                return (s == null) ? "~/album.ashx" : s;
            }
            set
            {
                ViewState["HandlerUrl"] = value;
            }
        }

        /// <summary>
        /// The info for the current image.
        /// </summary>
        public ImageInfo Image
        {
            get
            {
                if (_mode == AlbumHandlerMode.Page)
                {
                    if (_image == null)
                    {
                        _image = new ImageInfo(this, Path, _physicalPath, 0);
                    }
                    return _image;
                }
                return null;
            }
        }

        /// <summary>
        /// The CSS class for a thumbnail.
        /// </summary>
        [DefaultValue("albumFloat")]
        public string ImageDivCssClass
        {
            get
            {
                string s = ViewState["ImageDivCssClass"] as string;
                return (s == null) ? "albumFloat" : s;
            }
            set
            {
                ViewState["ImageDivCssClass"] = value;
            }
        }

        /// <summary>
        /// The list of image infos for the current folder.
        /// </summary>
        public List<ImageInfo> Images
        {
            get
            {
                if (_mode == AlbumHandlerMode.Folder)
                {
                    FileInfo[] pics = ImageHelper.GetImages(_physicalPath);
                    List<ImageInfo> images = null;
                    if (pics != null && pics.Length > 0)
                    {
                        string dirPrefix = Path;
                        if (!dirPrefix.EndsWith("/"))
                        {
                            dirPrefix += "/";
                        }
                        images = new List<ImageInfo>(pics.Length);
                        int i = 1;
                        foreach (FileInfo f in pics)
                        {
                            string picName = f.Name;
                            images.Add(new ImageInfo(this, dirPrefix + picName, f.FullName, i++));
                        }
                    }
                    return images;
                }
                return null;
            }
        }

        /// <summary>
        /// True if the class is used in Control mode (as opposed to handler mode).
        /// </summary>
        internal bool IsControl
        {
            get
            {
                return _isControl;
            }
        }

        /// <summary>
        /// CSS class for metadata field names.
        /// </summary>
        [DefaultValue("albumMetaName")]
        public string MetaNameCssClass
        {
            get
            {
                string s = ViewState["MetaNameCssClass"] as string;
                return (s == null) ? "albumMetaName" : s;
            }
            set
            {
                ViewState["MetaNameCssClass"] = value;
            }
        }

        /// <summary>
        /// CSS class for metadata section heads.
        /// </summary>
        [DefaultValue("albumMetaSectionHead")]
        public string MetaSectionHeadCssClass
        {
            get
            {
                string s = ViewState["MetaSectionHeadCssClass"] as string;
                return (s == null) ? "albumMetaSectionHead" : s;
            }
            set
            {
                ViewState["MetaSectionHeadCssClass"] = value;
            }
        }

        /// <summary>
        /// CSS class for metadata values.
        /// </summary>
        [DefaultValue("albumMetaValue")]
        public string MetaValueCssClass
        {
            get
            {
                string s = ViewState["MetaValueCssClass"] as string;
                return (s == null) ? "albumMetaValue" : s;
            }
            set
            {
                ViewState["MetaValueCssClass"] = value;
            }
        }

        /// <summary>
        /// Defines how the Album navigation links work.
        /// </summary>
        [DefaultValue(NavigationMode.Callback)]
        public NavigationMode NavigationMode
        {
            get
            {
                object o = ViewState["NavigationMode"];
                return (o == null) ? NavigationMode.Callback : (NavigationMode)o;
            }
            set
            {
                ViewState["NavigationMode"] = value;
            }
        }

        /// <summary>
        /// Info for the next image.
        /// </summary>
        public ImageInfo NextImage
        {
            get
            {
                if (_mode == AlbumHandlerMode.Page)
                {
                    if (_nextImage == null)
                    {
                        EnsureNextPrevious();
                    }
                    return _nextImage;
                }
                return null;
            }
        }

        /// <summary>
        /// Tooltip for the link to the next image.
        /// </summary>
        [Localizable(true), DefaultValue("Click to view the next picture")]
        public string NextImageTooltip
        {
            get
            {
                string s = ViewState["NextImageTooltip"] as string;
                return (s == null) ? "Click to view the next picture" : s;
            }
            set
            {
                ViewState["NextImageTooltip"] = value;
            }
        }

        /// <summary>
        /// Format string for the open folder tooltip.
        /// </summary>
        [Localizable(true), DefaultValue(@"Click to open ""{0}""")]
        public string OpenFolderTooltipFormatString
        {
            get
            {
                string s = ViewState["OpenFolderTooltipFormatString"] as string;
                return (s == null) ? @"Click to open ""{0}""" : s;
            }
            set
            {
                ViewState["OpenFolderTooltipFormatString"] = value;
            }
        }

        /// <summary>
        /// Template for the control in image preview mode.
        /// </summary>
        [PersistenceMode(PersistenceMode.InnerProperty), TemplateContainer(typeof(AlbumTemplateContainer))]
        public ITemplate PageModeTemplate
        {
            get
            {
                return _pageModeTemplate;
            }
            set
            {
                _pageModeTemplate = value;
            }
        }

        /// <summary>
        /// Information for the parent folder.
        /// </summary>
        public AlbumFolderInfo ParentFolder
        {
            get
            {
                if (_parentFolder == null)
                {
                    if (Path != "/")
                    {
                        int i = Path.LastIndexOf('/');
                        string parentDirPath;

                        if (i == 0)
                        {
                            parentDirPath = "/";
                        }
                        else
                        {
                            parentDirPath = Path.Substring(0, i);
                        }

                        if (parentDirPath == _requestDir || parentDirPath.StartsWith(_requestPathPrefix))
                        {
                            _parentFolder = new AlbumFolderInfo(this, parentDirPath, true);
                        }
                    }
                }
                return _parentFolder;
            }
        }

        /// <summary>
        /// The current virtual path.
        /// </summary>
        [DefaultValue("")]
        public string Path
        {
            get
            {
                string s = ViewState["Path"] as string;
                return (s == null) ? String.Empty : s;
            }
            set
            {
                _rawPath = value;
                string path = null;
                if (value != null)
                {
                    path = value.ToLower().Replace("\\", "/").Trim();

                    if (path != "/" && path.EndsWith("/"))
                    {
                        path = path.Substring(0, path.Length - 1);
                    }

                    if (path != _requestDir && !path.StartsWith(_requestPathPrefix))
                    {
                        ReportError("invalid path - not in the handler scope");
                    }

                    if (path.IndexOf("/.") >= 0)
                    {
                        ReportError("invalid path");
                    }
                }
                else
                {
                    path = _requestDir;
                    _rawPath = _requestDir;
                }
                ViewState["Path"] = path;

                _physicalPath = _request.MapPath(path, "/", false);
                if (!string.IsNullOrWhiteSpace(ImageHelper.PicturesDir))
                {
                    _physicalPath = _physicalPath.Replace(HttpRuntime.AppDomainAppPath.TrimEnd('\\'), ImageHelper.PicturesDir);
                }
                else
                {
                    ImageHelper.PicturesDir = HttpRuntime.AppDomainAppPath.TrimEnd('\\');
                }
            }
        }

        /// <summary>
        /// The fixed part of the path.
        /// </summary>
        internal string PathPrefix
        {
            get
            {
                return _requestPathPrefix;
            }
        }

        /// <summary>
        /// A permanent link to the current page with the Album in its current state.
        /// </summary>
        public string PermaLink
        {
            get
            {
                return ResolveClientUrl(Page.AppRelativeVirtualPath) +
                        "?albummode=" + _mode.ToString() +
                        "&albumpath=" + ImageHelper.UrlEncode(_rawPath);
            }
        }

        /// <summary>
        /// The information for the previous image.
        /// </summary>
        public ImageInfo PreviousImage
        {
            get
            {
                if (_mode == AlbumHandlerMode.Page)
                {
                    if (_previousImage == null)
                    {
                        EnsureNextPrevious();
                    }
                    return _previousImage;
                }
                return null;
            }
        }

        /// <summary>
        /// The tooltip for the link to the previous image.
        /// </summary>
        [Localizable(true), DefaultValue("Click to view the previous picture")]
        public string PreviousImageTooltip
        {
            get
            {
                string s = ViewState["PreviousImageTooltip"] as string;
                return (s == null) ? "Click to view the previous picture" : s;
            }
            set
            {
                ViewState["PreviousImageTooltip"] = value;
            }
        }

        /// <summary>
        /// The subfolders of the current folder.
        /// </summary>
        public List<AlbumFolderInfo> SubFolders
        {
            get
            {
                if (_mode == AlbumHandlerMode.Folder)
                {
                    DirectoryInfo[] dirs = ImageHelper.GetSubDirectories(_physicalPath);
                    List<AlbumFolderInfo> subFolders = null;
                    if (dirs != null && dirs.Length > 0)
                    {
                        subFolders = new List<AlbumFolderInfo>(dirs.Length);
                        string dirPrefix = Path;
                        if (!dirPrefix.EndsWith("/"))
                        {
                            dirPrefix += "/";
                        }
                        foreach (DirectoryInfo d in dirs)
                        {
                            subFolders.Add(new AlbumFolderInfo(this, dirPrefix + d.Name));
                        }
                    }
                    return subFolders;
                }
                return null;
            }
        }

        /// <summary>
        /// The title for the current Album view.
        /// </summary>
        public string Title
        {
            get
            {
                if (_title == null)
                {
                    if (_mode == AlbumHandlerMode.Folder)
                    {
                        _title = _rawPath.Substring(_rawPath.LastIndexOf('/') + 1);
                    }
                    else
                    {
                        FileInfo pictureFileInfo = new FileInfo(_physicalPath);
                        Metadata data = ImageHelper.GetImageData(pictureFileInfo);

                        // First, check for the IPTC Title tag
                        IptcDirectory iptcDir = (IptcDirectory)data.GetDirectory(typeof(IptcDirectory));
                        if (iptcDir.ContainsTag(IptcDirectory.TAG_OBJECT_NAME))
                        {
                            _title = iptcDir.GetString(IptcDirectory.TAG_OBJECT_NAME);
                        }
                        else
                        {
                            // Then, try the Exif Title tag used by XP (in Property / Summary dialog)
                            ExifDirectory exifDir = (ExifDirectory)data.GetDirectory(typeof(ExifDirectory));
                            if (exifDir.ContainsTag(ExifDirectory.TAG_XP_TITLE))
                            {
                                _title = exifDir.GetDescription(ExifDirectory.TAG_XP_TITLE);
                            }
                            else
                            {
                                // Default the title to teh file name
                                _title = System.IO.Path.GetFileNameWithoutExtension(_physicalPath);
                            }
                        }
                    }
                }
                return _title;
            }
        }

        /// <summary>
        /// The description for the current Album view.
        /// </summary>
        public string Description
        {
            get
            {
                if (_description == null)
                {
                    _description = String.Empty;
                    if (_mode == AlbumHandlerMode.Page)
                    {
                        FileInfo pictureFileInfo = new FileInfo(_physicalPath);
                        Metadata data = ImageHelper.GetImageData(pictureFileInfo);

                        // Try the Exif Description tag used by XP (in Property / Summary dialog)
                        ExifDirectory exifDir = (ExifDirectory)data.GetDirectory(typeof(ExifDirectory));
                        if (exifDir.ContainsTag(ExifDirectory.TAG_XP_COMMENTS))
                        {
                            _description = exifDir.GetDescription(ExifDirectory.TAG_XP_COMMENTS);
                        }
                    }
                }

                return _description;
            }
        }

        protected override void CreateChildControls()
        {
            if ((FolderModeTemplate != null) && (_mode == AlbumHandlerMode.Folder))
            {
                Controls.Clear();
                _parentFolder = null;
                AlbumTemplateContainer container = new AlbumTemplateContainer(this);
                container.EnableViewState = false;
                FolderModeTemplate.InstantiateIn(container);
                Controls.Add(container);
            }
            if ((PageModeTemplate != null) && (_mode == AlbumHandlerMode.Page))
            {
                Controls.Clear();
                _image = null;
                AlbumTemplateContainer container = new AlbumTemplateContainer(this);
                container.EnableViewState = false;
                PageModeTemplate.InstantiateIn(container);
                Controls.Add(container);
            }
        }

        /// <summary>
        /// Ensures that the next and previous image infos have been computed.
        /// </summary>
        private void EnsureNextPrevious()
        {
            bool pictureFound = false;
            string dirPath = System.IO.Path.GetDirectoryName(_physicalPath);
            FileInfo[] pics = ImageHelper.GetImages(dirPath);

            string prev = null;
            string next = null;
            string prevPhysPath = null;
            string nextPhysPath = null;
            string parentPath = ParentFolder.Path;
            int index = ImageHelper.GetSubDirectories(dirPath).Length + 1;

            if (pics != null && pics.Length > 0)
            {
                foreach (FileInfo p in pics)
                {
                    string picture = p.Name.ToLower(CultureInfo.InvariantCulture);

                    if (String.Equals(p.FullName, _physicalPath, StringComparison.InvariantCultureIgnoreCase))
                    {
                        pictureFound = true;
                    }
                    else if (pictureFound)
                    {
                        nextPhysPath = p.FullName;
                        next = parentPath + '/' + picture;
                        break;
                    }
                    else
                    {
                        prevPhysPath = p.FullName;
                        prev = parentPath + '/' + picture;
                    }
                    index++;
                }
            }

            if (!pictureFound)
            {
                prevPhysPath = null;
                nextPhysPath = null;
            }
            if (prev != null)
            {
                _previousImage = new ImageInfo(this, prev, prevPhysPath, index - 2);
            }
            if (next != null)
            {
                _nextImage = new ImageInfo(this, next, nextPhysPath, index);
            }
        }

        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);
            _isControl = true;
            _filePath = Page.ResolveUrl(HandlerUrl);
            _requestPathPrefix = _filePath.Substring(0, _filePath.LastIndexOf('/') + 1).ToLower();

            _requestDir = (_requestPathPrefix == "/") ?
                "/" :
                _requestPathPrefix.Substring(0, _requestPathPrefix.Length - 1);
            _request = Request;
            _response = Response;

            ParseParams();
            ChildControlsCreated = false;
        }

        protected override void OnPreRender(EventArgs e)
        {
            base.OnPreRender(e);
            Page.ClientScript.RegisterClientScriptBlock(typeof(Album), "AlbumScript", AlbumScript, true);
            if (Request.Browser.SupportsCallback)
            {
                Page.ClientScript.RegisterClientScriptBlock(typeof(Album), "CallbackScript", CallbackScript, true);
            }
        }

        public override void RenderControl(HtmlTextWriter writer)
        {
            if (((FolderModeTemplate != null) && (_mode == AlbumHandlerMode.Folder)) ||
                ((PageModeTemplate != null) && (_mode == AlbumHandlerMode.Page)))
            {
                Controls[0].DataBind();
            }
            RenderPrivate(writer);
        }

        void IHttpHandler.ProcessRequest(HttpContext context)
        {
            _request = context.Request;
            _response = context.Response;

            RenderPrivate(new HtmlTextWriter(_response.Output));
        }

        /// <summary>
        /// Directs to the right rendering methods according to the mode.
        /// </summary>
        /// <param name="writer">The writer to write to.</param>
        private void RenderPrivate(HtmlTextWriter writer)
        {
            if (!_isControl)
            {
                _filePath = _request.FilePath;
                _requestPathPrefix = _filePath.Substring(0, _filePath.LastIndexOf('/') + 1).ToLower();

                _requestDir = (_requestPathPrefix == "/") ?
                    "/" :
                    _requestPathPrefix.Substring(0, _requestPathPrefix.Length - 1);

                ParseParams();
            }

            if ((_mode == AlbumHandlerMode.Folder) ||
                (_mode == AlbumHandlerMode.Thumbnail))
            {

                if (!Directory.Exists(_physicalPath))
                {
                    throw new HttpException(404, "Directory Not Found");
                }
            }
            else if ((_mode != AlbumHandlerMode.Css) &&
                (_mode != AlbumHandlerMode.Blank) &&
                !File.Exists(_physicalPath))
            {

                throw new HttpException(404, "File Not Found");
            }

            switch (_mode)
            {
                case AlbumHandlerMode.Folder:
                    GenerateFolderPage(writer, Path);
                    break;

                case AlbumHandlerMode.Page:
                    string dir = Path.Substring(0, Path.LastIndexOf('/') + 1);

                    if (dir != "/")
                    {
                        dir = dir.Substring(0, dir.Length - 1);
                    }

                    GeneratePreviewPage(
                        writer,
                        dir,
                        _request.MapPath(dir),
                        Path.Substring(Path.LastIndexOf('/') + 1).ToLower());
                    break;

                case AlbumHandlerMode.Preview:
                    ImageHelper.GenerateResizedImageResponse(_physicalPath, ImageHelper.PreviewSize, _response);
                    break;

                case AlbumHandlerMode.Thumbnail:
                    ImageHelper.GenerateSpriteStripResponse(_physicalPath, ImageHelper.ThumbnailSize, _response);
                    break;

                case AlbumHandlerMode.Css:
                    ImageHelper.GenerateCssResponse(_response);
                    break;

                case AlbumHandlerMode.Blank:
                    ImageHelper.GenerateBlankImage(_response);
                    break;

                default:
                    ReportError("invalid mode");
                    break;
            }
        }

        bool IHttpHandler.IsReusable
        {
            get { return false; }
        }

        /// <summary>
        /// Does the actual rendering for the folder mode.
        /// </summary>
        /// <param name="writer">The writer to write to.</param>
        /// <param name="dirPath">The virtual path to the folder.</param>
        private void GenerateFolderPage(HtmlTextWriter writer, string dirPath)
        {
            // There's a small concurrency issue here which is that the index of a thumbnail
            // may change between the time the page is rendered and the time the thumbnails strip
            // is rendered.
            if (_isControl)
            {
                if (!Page.IsCallback)
                {
                    writer.AddAttribute(HtmlTextWriterAttribute.Id, ClientID);
                    writer.AddAttribute(HtmlTextWriterAttribute.Class, CssClass);
                    writer.RenderBeginTag(HtmlTextWriterTag.Div);
                }
            }
            else
            {
                writer.Write(@"<!DOCTYPE html>");
                writer.RenderBeginTag(HtmlTextWriterTag.Html);
                writer.RenderBeginTag(HtmlTextWriterTag.Head);
                writer.AddAttribute(HtmlTextWriterAttribute.Rel, "Stylesheet");
                writer.AddAttribute(HtmlTextWriterAttribute.Type, "text/css");
                writer.AddAttribute(HtmlTextWriterAttribute.Href, "?albummode=css");
                writer.RenderBeginTag(HtmlTextWriterTag.Link);
                writer.RenderEndTag(); // link
                writer.RenderBeginTag(HtmlTextWriterTag.Title);
                writer.WriteEncodedText(Title);
                writer.RenderEndTag(); // title
                writer.RenderEndTag(); // head
                writer.RenderBeginTag(HtmlTextWriterTag.Body);
            }

            if (FolderModeTemplate != null)
            {
                Controls[0].RenderControl(writer);
            }
            else
            {
                if (dirPath != "/")
                {
                    int slash = dirPath.LastIndexOf('/');
                    string parentDirPath;

                    if (slash == 0)
                    {
                        parentDirPath = "/";
                    }
                    else
                    {
                        parentDirPath = dirPath.Substring(0, slash);
                    }

                    if (parentDirPath == _requestDir || parentDirPath.StartsWith(_requestPathPrefix))
                    {
                        RenderImageCell(writer, ParentFolder.IconUrl, 0, ParentFolder.Link, BackToParentTooltip, BackToParentText);
                    }
                }

                int i = 1;
                string spriteUrl = "album.ashx?albummode=thumbnail&albumpath=" + ImageHelper.UrlEncode(dirPath);

                List<AlbumFolderInfo> folders = SubFolders;
                if (folders != null && folders.Count > 0)
                {
                    foreach (AlbumFolderInfo folder in folders)
                    {
                        RenderImageCell(writer, spriteUrl, i++, folder.Link, String.Format(OpenFolderTooltipFormatString, folder.Name), folder.Name);
                    }
                }

                List<ImageInfo> images = Images;
                if (images != null && images.Count > 0)
                {
                    foreach (ImageInfo image in images)
                    {
                        RenderImageCell(writer, spriteUrl, i++, image.Link, String.Format(DisplayImageTooltip, image.Caption), image.Caption);
                    }
                }
            }

            if (_isControl)
            {
                if (!Page.IsCallback)
                {
                    writer.RenderEndTag(); // div
                }
            }
            else
            {
                writer.RenderEndTag(); // body
                writer.RenderEndTag(); // html
            }
        }

        /// <summary>
        /// Renders the HTML for a thumbnail, using sprites.
        /// </summary>
        /// <param name="writer"></param>
        /// <param name="url"></param>
        /// <param name="link"></param>
        /// <param name="tooltip"></param>
        /// <param name="legend"></param>
        private void RenderImageCell(HtmlTextWriter writer, string url, int spriteIndex, string link, string tooltip, string legend)
        {
            writer.AddAttribute(HtmlTextWriterAttribute.Class, ImageDivCssClass);
            writer.RenderBeginTag(HtmlTextWriterTag.Div);
            writer.AddAttribute(HtmlTextWriterAttribute.Href, link, true);
            writer.RenderBeginTag(HtmlTextWriterTag.A);
            writer.AddAttribute(HtmlTextWriterAttribute.Class, "blank");
            writer.AddAttribute(HtmlTextWriterAttribute.Src, "album.ashx?albummode=blank", true);
            writer.AddAttribute(HtmlTextWriterAttribute.Alt, tooltip, true);
            writer.AddAttribute(HtmlTextWriterAttribute.Height, ImageHelper.ThumbnailSize.ToString());
            writer.AddAttribute(HtmlTextWriterAttribute.Width, ImageHelper.ThumbnailSize.ToString());
            writer.AddStyleAttribute("background",
                string.Format("url('{0}') no-repeat -{1}px {2}px", url, spriteIndex * (ImageHelper.ThumbnailSize + 1), 0));
            writer.RenderBeginTag(HtmlTextWriterTag.Img);
            writer.RenderEndTag(); // img
            writer.WriteBreak();
            writer.AddAttribute(HtmlTextWriterAttribute.Class, "albumLegend");
            writer.RenderBeginTag(HtmlTextWriterTag.Span);
            writer.Write(TransformLegend(legend));
            writer.RenderEndTag(); // span
            writer.RenderEndTag(); // a
            writer.RenderEndTag(); // div
        }

        public string TransformLegend(string legend)
        {
            if (ImageHelper.ThumbnailCaptionMaxChars <= 0 || string.IsNullOrEmpty(legend))
            {
                return string.Empty;
            }
            if (legend.Length <= ImageHelper.ThumbnailCaptionMaxChars)
            {
                return legend;
            }
            if (ImageHelper.ThumbnailCaptionMaxChars <= 3)
            {
                return legend.Substring(0, ImageHelper.ThumbnailCaptionMaxChars);
            }
            return legend.Substring(0, ImageHelper.ThumbnailCaptionMaxChars - 3) + "...";
        }

        /// <summary>
        /// Gets the top n images in a folder, sorted by date descending.
        /// </summary>
        /// <param name="numberOfImages">Maximum number of images to return.</param>
        /// <param name="includeSubFolders">True if subfolders should be included.</param>
        /// <returns>The image infos.</returns>
        public List<ImageInfo> GetImages(int numberOfImages, bool includeSubFolders)
        {
            if (_mode == AlbumHandlerMode.Folder)
            {
                FileInfo[] pics = ImageHelper.GetImages(_physicalPath, includeSubFolders);
                List<ImageInfo> images = null;
                if (pics != null && pics.Length > 0)
                {
                    string dirPrefix = Path;
                    if (!dirPrefix.EndsWith("/"))
                    {
                        dirPrefix += "/";
                    }
                    images = new List<ImageInfo>(numberOfImages);
                    int n = 1;
                    foreach (FileInfo f in pics)
                    {
                        string picName = f.Name;
                        images.Add(new ImageInfo(this, dirPrefix + picName, f.FullName, n));
                        if (n++ >= numberOfImages)
                        {
                            break;
                        }
                    }
                }
                return images;
            }
            return null;
        }

        /// <summary>
        /// Renders an image preview page.
        /// </summary>
        /// <param name="writer">The writer to render to.</param>
        /// <param name="dirPath">The virtual path of the directory.</param>
        /// <param name="dirPhysicalPath">The physical path of the directory.</param>
        /// <param name="page">The name of the image.</param>
        void GeneratePreviewPage(HtmlTextWriter writer, string dirPath, string dirPhysicalPath, string page)
        {
            string dirPrefix = dirPath;
            if (!dirPrefix.EndsWith("/"))
            {
                dirPrefix += "/";
            }

            string pictPath = dirPrefix + page;

            if (_isControl)
            {
                if (!Page.IsCallback)
                {
                    writer.AddAttribute(HtmlTextWriterAttribute.Id, ClientID);
                    writer.AddAttribute(HtmlTextWriterAttribute.Class, CssClass);
                    writer.RenderBeginTag(HtmlTextWriterTag.Div);
                }
            }
            else
            {
                writer.Write(@"<!DOCTYPE html>");
                writer.RenderBeginTag(HtmlTextWriterTag.Html);
                writer.RenderBeginTag(HtmlTextWriterTag.Head);
                writer.AddAttribute(HtmlTextWriterAttribute.Rel, "Stylesheet");
                writer.AddAttribute(HtmlTextWriterAttribute.Type, "text/css");
                writer.AddAttribute(HtmlTextWriterAttribute.Href, "?albummode=css");
                writer.RenderBeginTag(HtmlTextWriterTag.Link);
                writer.RenderEndTag(); // link
                writer.RenderBeginTag(HtmlTextWriterTag.Title);
                writer.WriteEncodedText(Title);
                writer.RenderEndTag(); // title
                writer.RenderBeginTag(HtmlTextWriterTag.Script);
                writer.Write(AlbumScript);
                writer.RenderEndTag(); // script
                writer.RenderEndTag(); // head
                writer.RenderBeginTag(HtmlTextWriterTag.Body);
            }

            if (PageModeTemplate != null)
            {
                Controls[0].RenderControl(writer);
            }
            else
            {
                EnsureNextPrevious();

                // Up to folder view
                RenderImageCell(writer, ParentFolder.IconUrl, 0, ParentFolder.Link, BackToFolderViewTooltip, "");

                // Previous image
                if (PreviousImage != null)
                {
                    RenderImageCell(writer, PreviousImage.IconUrl, PreviousImage.Index, PreviousImage.Link, PreviousImageTooltip, PreviousImage.Caption);
                }
                else
                {
                    writer.Write("&nbsp;");
                }

                // Preview image
                writer.AddAttribute(HtmlTextWriterAttribute.Class, ImageDivCssClass);
                writer.AddAttribute(HtmlTextWriterAttribute.Href, pictPath, true);
                writer.AddAttribute(HtmlTextWriterAttribute.Target, "_blank");
                writer.RenderBeginTag(HtmlTextWriterTag.A);
                writer.AddAttribute(HtmlTextWriterAttribute.Src, Image.PreviewUrl, true);
                writer.AddAttribute(HtmlTextWriterAttribute.Alt, DisplayFullResolutionTooltip, true);
                writer.RenderBeginTag(HtmlTextWriterTag.Img);
                writer.RenderEndTag(); // img
                writer.RenderEndTag(); // a

                // Next image
                if (NextImage != null)
                {
                    RenderImageCell(writer, NextImage.IconUrl, NextImage.Index, NextImage.Link, NextImageTooltip, NextImage.Caption);
                }
                else
                {
                    writer.Write("&nbsp;");
                }

                // Details section
                writer.AddAttribute(HtmlTextWriterAttribute.Class, DetailsCssClass);
                writer.RenderBeginTag(HtmlTextWriterTag.Div);
                // Details toggle link
                writer.AddAttribute(HtmlTextWriterAttribute.Href, "javascript:void(0)");
                writer.AddAttribute(HtmlTextWriterAttribute.Onclick,
                    @"photoAlbumDetails(""" +
                    (_isControl ? ClientID : String.Empty) +
                    @""")", true);
                writer.AddAttribute(HtmlTextWriterAttribute.Class, DetailsLinkCssClass);
                writer.RenderBeginTag(HtmlTextWriterTag.A);
                writer.Write(DetailsText);
                writer.RenderEndTag(); // a

                // Details table
                writer.AddAttribute(HtmlTextWriterAttribute.Border, "0");
                writer.AddAttribute(HtmlTextWriterAttribute.Id,
                    (_isControl ? ClientID : String.Empty) + "_details", true);
                writer.AddStyleAttribute(HtmlTextWriterStyle.Display, "none");
                writer.RenderBeginTag(HtmlTextWriterTag.Table);

                Dictionary<string, List<KeyValuePair<string, string>>> metadata = Image.MetaData;
                foreach (KeyValuePair<string, List<KeyValuePair<string, string>>> dir in metadata)
                {
                    writer.RenderBeginTag(HtmlTextWriterTag.Tr);
                    writer.AddAttribute(HtmlTextWriterAttribute.Valign, "top");
                    writer.AddAttribute(HtmlTextWriterAttribute.Class, MetaSectionHeadCssClass);
                    writer.AddAttribute(HtmlTextWriterAttribute.Colspan, "2");
                    writer.RenderBeginTag(HtmlTextWriterTag.Td);
                    writer.WriteEncodedText(dir.Key);
                    writer.RenderEndTag(); // td
                    writer.RenderEndTag(); // tr

                    foreach (KeyValuePair<string, string> data in dir.Value)
                    {
                        writer.RenderBeginTag(HtmlTextWriterTag.Tr);
                        writer.AddAttribute(HtmlTextWriterAttribute.Valign, "top");
                        writer.AddAttribute(HtmlTextWriterAttribute.Class, MetaNameCssClass);
                        writer.RenderBeginTag(HtmlTextWriterTag.Td);
                        writer.WriteEncodedText(data.Key);
                        writer.RenderEndTag(); // td
                        writer.AddAttribute(HtmlTextWriterAttribute.Valign, "top");
                        writer.AddAttribute(HtmlTextWriterAttribute.Class, MetaValueCssClass);
                        writer.RenderBeginTag(HtmlTextWriterTag.Td);
                        writer.WriteEncodedText(data.Value);
                        writer.RenderEndTag(); // td
                        writer.RenderEndTag(); // tr
                    }
                }

                writer.RenderEndTag(); // table
                writer.RenderEndTag(); // div
            }

            if (_isControl)
            {
                if (!Page.IsCallback)
                {
                    writer.RenderEndTag(); // div
                }
            }
            else
            {
                writer.RenderEndTag(); // body
                writer.RenderEndTag(); // html
            }
        }

        /// <summary>
        /// Sends a 500 error to the client.
        /// </summary>
        /// <param name="msg">The error message.</param>
        void ReportError(string msg)
        {
            throw new HttpException(500, msg);
        }

        /// <summary>
        /// Parses the parameters from the querystring.
        /// </summary>
        void ParseParams()
        {
            ParseParams(_request.QueryString);
        }

        /// <summary>
        /// Parses the parameters.
        /// </summary>
        /// <param name="paramsCollection">The parameter collection to parse from.</param>
        void ParseParams(NameValueCollection paramsCollection)
        {
            string s;

            s = paramsCollection["albummode"];

            if (s != null)
            {
                try
                {
                    _mode = (AlbumHandlerMode)Enum.Parse(typeof(AlbumHandlerMode), s, true);
                }
                catch
                {
                }

                if (_mode == AlbumHandlerMode.Unknown)
                {
                    ReportError("invalid mode");
                }
            }
            else
            {
                _mode = AlbumHandlerMode.Folder;
            }

            s = paramsCollection["albumpath"];

            Path = s;
        }

        void IPostBackEventHandler.RaisePostBackEvent(string eventArgument)
        {
            Page.ClientScript.ValidateEvent(UniqueID, eventArgument);
            char command = eventArgument[0];
            string arg = eventArgument.Substring(1);
            switch (command)
            {
                case FolderCommand:
                    _mode = AlbumHandlerMode.Folder;
                    Path = arg;
                    break;
                case PageCommand:
                    _mode = AlbumHandlerMode.Page;
                    Path = arg;
                    break;
            }
        }

        private string _callbackEventArg;

        string ICallbackEventHandler.GetCallbackResult()
        {
            ((IPostBackEventHandler)this).RaisePostBackEvent(_callbackEventArg);
            ChildControlsCreated = false;
            using (StringWriter swriter = new StringWriter())
            {
                using (HtmlTextWriter writer = new HtmlTextWriter(swriter))
                {
                    EnsureChildControls();
                    RenderControl(writer);
                }
                return swriter.ToString();
            }
        }

        void ICallbackEventHandler.RaiseCallbackEvent(string eventArgument)
        {
            _callbackEventArg = eventArgument;
        }
    }
}

#region MetaDataExtractor
//////////////////////////////////////////////////////////////////////////////////////////////
// From here on, the code is Drew Noakes and Renaud Ferret's code
// (see comments on top of this file).
/// <summary>
/// This class was first written by Drew Noakes in Java.
///
/// This is public domain software - that is, you can do whatever you want
/// with it, and include it software that is licensed under the GNU or the
/// BSD license, or whatever other licence you choose, including proprietary
/// closed source licenses.  I do ask that you leave this header in tact.
///
/// If you make modifications to this code that you think would benefit the
/// wider community, please send me a copy and I'll post it on my site.
///
/// If you make use of this code, Drew Noakes will appreciate hearing
/// about it: <a href="mailto:drew@drewnoakes.com">drew@drewnoakes.com</a>
///
/// Latest Java version of this software kept at
/// <a href="http://drewnoakes.com">http://drewnoakes.com/</a>
///
/// Created on 28 April 2002, 17:40
/// Modified 04 Aug 2002
/// - Adjusted javadoc
/// - Added
/// Modified 29 Oct 2002 (v1.2)
/// - Stored IFD directories in separate tag-spaces
/// - iterator() now returns an Iterator over a list of TagValue objects
/// - More get///Description() methods to detail GPS tags, among others
/// - Put spaces between words of tag name for presentation reasons (they had no  significance in compound form)
///
/// The C# class was made by Ferret Renaud:
/// <a href="mailto:renaud91@free.fr">renaud91@free.fr</a>
/// If you find a bug in the C# code, feel free to mail me.
/// </summary>
namespace Com.Drew.Lang
{
    /// <summary>
    /// Created on 6 May 2002, 18:06
    /// Updated 26 Aug 2002 by Drew
    /// - Added toSimpleString() method, which returns a simplified and hopefully
    ///   more readable version of the Rational.  i.e. 2/10 -> 1/5, and 10/2 -> 5
    /// Modified 29 Oct 2002 (v1.2)
    /// - Improved toSimpleString() to factor more complex rational numbers into
    ///   a simpler form i.e. 10/15 -> 2/3
    /// - toSimpleString() now accepts a boolean flag, 'allowDecimals' which
    ///   will display the rational number in decimal form if it fits within 5
    ///   digits i.e. 3/4 -> 0.75 when allowDecimal == true
    /// </summary>
    [Serializable]
    public class Rational
    {
        /// <summary>
        /// Holds the numerator.
        /// </summary>
        private readonly int numerator;

        /// <summary>
        /// Holds the denominator.
        /// </summary>
        private readonly int denominator;

        private int maxSimplificationCalculations = 1000;

        /// <summary>
        /// Creates a new instance of Rational.
        /// Rational objects are immutable, so once you've set your numerator and
        /// denominator values here, you're stuck with them!
        /// </summary>
        /// <param name="aNumerator">a numerator</param>
        /// <param name="aDenominator"> a denominator</param>
        public Rational(int aNumerator, int aDenominator)
        {
            this.numerator = aNumerator;
            this.denominator = aDenominator;
        }

        /// <summary>
        /// Returns the value of the specified number as a double. This may involve rounding.
        /// </summary>
        /// <returns>the numeric value represented by this object after conversion to type double.</returns>
        public double DoubleValue()
        {
            return (double)numerator / (double)denominator;
        }

        /// <summary>
        /// Returns the value of the specified number as a float. This may involve rounding.
        /// </summary>
        /// <returns>the numeric value represented by this object after conversion to type float.</returns>
        public float FloatValue()
        {
            return (float)numerator / (float)denominator;
        }

        /// <summary>
        /// Returns the value of the specified number as a byte.
        /// This may involve rounding or truncation.
        /// This implementation simply casts the result of doubleValue() to byte.
        /// </summary>
        /// <returns>the numeric value represented by this object after conversion to type byte.</returns>
        public byte ByteValue()
        {
            return (byte)DoubleValue();
        }

        /// <summary>
        /// Returns the value of the specified number as an int.
        /// This may involve rounding or truncation.
        /// This implementation simply casts the result of doubleValue() to int.
        /// </summary>
        /// <returns>the numeric value represented by this object after conversion to type int.</returns>
        public int IntValue()
        {
            return (int)DoubleValue();
        }

        /// <summary>
        /// Returns the value of the specified number as a long.
        /// This may involve rounding or truncation.
        /// This implementation simply casts the result of doubleValue() to long.
        /// </summary>
        /// <returns>the numeric value represented by this object after conversion to type long.</returns>
        public long LongValue()
        {
            return (long)DoubleValue();
        }

        /// <summary>
        /// Returns the value of the specified number as a short.
        /// This may involve rounding or truncation.
        /// This implementation simply casts the result of doubleValue() to short.
        /// </summary>
        /// <returns>the numeric value represented by this object after conversion to type short.</returns>
        public short ShortValue()
        {
            return (short)DoubleValue();
        }

        /// <summary>
        /// Returns the denominator.
        /// </summary>
        /// <returns>the denominator.</returns>
        public int GetDenominator()
        {
            return this.denominator;
        }

        /// <summary>
        /// Returns the numerator.
        /// </summary>
        /// <returns>the numerator.</returns>
        public int GetNumerator()
        {
            return this.numerator;
        }

        /// <summary>
        /// Returns the reciprocal value of this obejct as a new Rational.
        /// </summary>
        /// <returns>the reciprocal in a new object</returns>
        public Rational GetReciprocal()
        {
            return new Rational(this.denominator, this.numerator);
        }

        /// <summary>
        /// Checks if this rational number is an Integer, either positive or negative.
        /// </summary>
        /// <returns>true is Rational is an integer, false otherwize</returns>
        public bool IsInteger()
        {
            return (denominator == 1
                || (denominator != 0 && (numerator % denominator == 0))
                || (denominator == 0 && numerator == 0));
        }

        /// <summary>
        /// Returns a string representation of the object of form numerator/denominator.
        /// </summary>
        /// <returns>a string representation of the object.</returns>
        public override String ToString()
        {
            return numerator + "/" + denominator;
        }

        /// <summary>
        /// Returns the simplest represenation of this Rational's value possible.
        /// </summary>
        /// <param name="allowDecimal">if true then decimal will be showned</param>
        /// <returns>the simplest represenation of this Rational's value possible.</returns>
        public String ToSimpleString(bool allowDecimal)
        {
            if (denominator == 0 && numerator != 0)
            {
                return this.ToString();
            }
            else if (IsInteger())
            {
                return IntValue().ToString();
            }
            else if (numerator != 1 && denominator % numerator == 0)
            {
                // common factor between denominator and numerator
                int newDenominator = denominator / numerator;
                return new Rational(1, newDenominator).ToSimpleString(allowDecimal);
            }
            else
            {
                Rational simplifiedInstance = GetSimplifiedInstance();
                if (allowDecimal)
                {
                    String doubleString =
                        simplifiedInstance.DoubleValue().ToString();
                    if (doubleString.Length < 5)
                    {
                        return doubleString;
                    }
                }
                return simplifiedInstance.ToString();
            }
        }


        /// <summary>
        /// Decides whether a brute-force simplification calculation should be avoided by comparing the
        /// maximum number of possible calculations with some threshold.
        /// </summary>
        /// <returns>true if the simplification should be performed, otherwise false</returns>
        private bool TooComplexForSimplification()
        {
            double maxPossibleCalculations =
                (((double)(Math.Min(denominator, numerator) - 1) / 5d) + 2);
            return maxPossibleCalculations > maxSimplificationCalculations;
        }

        /// <summary>
        /// Compares two Rational instances, returning true if they are mathematically equivalent.
        /// </summary>
        /// <param name="obj">the Rational to compare this instance to.</param>
        /// <returns>true if instances are mathematically equivalent, otherwise false. Will also return false if obj is not an instance of Rational.</returns>
        public override bool Equals(object obj)
        {
            if (obj == null) return false;
            if (obj == this) return true;
            if (obj is Rational)
            {
                Rational that = (Rational)obj;
                return this.DoubleValue() == that.DoubleValue();
            }
            return false;
        }

        /// <summary>
        /// Simplifies the Rational number.
        ///
        /// Prime number series: 1, 2, 3, 5, 7, 9, 11, 13, 17
        ///
        /// To reduce a rational, need to see if both numerator and denominator are divisible
        /// by a common factor.  Using the prime number series in ascending order guarantees
        /// the minimun number of checks required.
        ///
        /// However, generating the prime number series seems to be a hefty task.  Perhaps
        /// it's simpler to check if both d & n are divisible by all numbers from 2 ->
        /// (Math.min(denominator, numerator) / 2).  In doing this, one can check for 2
        /// and 5 once, then ignore all even numbers, and all numbers ending in 0 or 5.
        /// This leaves four numbers from every ten to check.
        ///
        /// Therefore, the max number of pairs of modulus divisions required will be:
        ///
        ///    4   Math.min(denominator, numerator) - 1
        ///   -- * ------------------------------------ + 2
        ///   10                    2
        ///
        ///   Math.min(denominator, numerator) - 1
        /// = ------------------------------------ + 2
        ///                  5
        /// </summary>
        /// <returns>a simplified instance, or if the Rational could not be simpliffied, returns itself (unchanged)</returns>
        public Rational GetSimplifiedInstance()
        {
            if (TooComplexForSimplification())
            {
                return this;
            }
            for (int factor = 2;
                factor <= Math.Min(denominator, numerator);
                factor++)
            {
                if ((factor % 2 == 0 && factor > 2)
                    || (factor % 5 == 0 && factor > 5))
                {
                    continue;
                }
                if (denominator % factor == 0 && numerator % factor == 0)
                {
                    // found a common factor
                    return new Rational(numerator / factor, denominator / factor);
                }
            }
            return this;
        }

        /// <summary>
        /// Returns the hash code of the object
        /// </summary>
        /// <returns>the hash code of the object</returns>
        public override int GetHashCode()
        {
            return this.denominator.GetHashCode() >> this.numerator.GetHashCode() * this.DoubleValue().GetHashCode();
        }
    }

    /// <summary>
    /// This is Compound exception
    /// </summary>
    public class CompoundException : Exception
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="message">The error message</param>
        public CompoundException(string message)
            : base(message)
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="message">The error message</param>
        /// <param name="cause">The cause of the exception</param>
        public CompoundException(string message, Exception cause)
            : base(message, cause)
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="cause">The cause of the exception</param>
        public CompoundException(Exception cause)
            : base(null, cause)
        {
        }
    }
}

namespace Com.Utilities
{
    public class ResourceBundle // : IResourceReader
    {

        protected Dictionary<string, string> resourceManager;
        private static readonly Dictionary<string, Dictionary<string, string>> Resources;

        public string this[string aKey]
        {
            get
            {
                return this[aKey, new string[] { null }];
            }
        }

        public string this[string aKey, string fillGapWith]
        {
            get
            {
                return this[aKey, new string[] { fillGapWith }];
            }
        }

        public string this[string aKey, string fillGap0, string fillGap1]
        {
            get
            {
                return this[aKey, new string[] { fillGap0, fillGap1 }];
            }
        }


        public string this[string aKey, string[] fillGapWith]
        {
            get
            {
                string resu = this.resourceManager[aKey];
                if (resu == null)
                {
                    throw new Exception("\"" + aKey + "\" No found");
                }
                return replace(resu, fillGapWith);
            }
        }

        static ResourceBundle()
        {
            Resources = new Dictionary<string, Dictionary<string, string>>();

            Dictionary<string, string> Commons = new Dictionary<string, string>();
            Resources["Commons"] = Commons;
            Commons["2_X_DIGITAL_ZOOM"] = "2x digital zoom";
            Commons["AE_GOOD"] = "AE good";
            Commons["AI_FOCUS"] = "AI Focus";
            Commons["AI_SERVO"] = "AI Servo";
            Commons["APERTURE"] = "F {0}";
            Commons["APERTURE_PRIORITY"] = "Aperture priority";
            Commons["APERTURE_PRIORITY_AE"] = "Aperture priority AE";
            Commons["AUTO"] = "Auto";
            Commons["AUTO_AND_RED_YEY_REDUCTION"] = "Auto and red-eye reduction";
            Commons["AUTO_FOCUS"] = "Auto focus";
            Commons["AUTO_FOCUS_GOOD"] = "Auto focus good";
            Commons["AUTO_SELECTED"] = "Auto selected";
            Commons["AVERAGE"] = "Average";
            Commons["AV_PRIORITY"] = "Av-priority";
            Commons["A_DEP"] = "A-DEP";
            Commons["BITS"] = "{0} bits";
            Commons["COMPONENT_DATA"] = "{0} component: Quantization table {1}, Sampling factors {2} horiz/{3} vert";
            Commons["BITS_COMPONENT_PIXEL"] = "{0} bits/component/pixel";
            Commons["BITS_PIXEL"] = "{0} bits/pixel";
            Commons["BIT_PIXEL"] = "{0} bit/pixel";
            Commons["BLUR_WARNING"] = "Blur warning";
            Commons["BOTTOM"] = "Bottom";
            Commons["BOTTOM_LEFT_SIDE"] = "bottom, left side";
            Commons["BOTTOM_RIGHT_SIDE"] = "bottom, right side";
            Commons["BOTTOM_TO_TOP_PAN_DIR"] = "Bottom to top panorama direction";
            Commons["BRIGHT_M"] = "Bright -";
            Commons["BRIGHT_P"] = "Bright +";
            Commons["BYTES"] = "{0} bytes";
            Commons["B_W"] = "B&W";
            Commons["CCD_P_1"] = "+1.0";
            Commons["CCD_P_2"] = "+2.0";
            Commons["CCD_P_3"] = "+3.0";
            Commons["CENTER"] = "Center";
            Commons["CENTER_OF_PIXEL_ARRAY"] = "Center of pixel array";
            Commons["CENTER_WEIGHTED_AVERAGE"] = "Center weighted average";
            Commons["CENTRE_WEIGHTED"] = "Centre weighted";
            Commons["CHUNKY"] = "Chunky (contiguous for each subsampling pixel)";
            Commons["CLOUDY"] = "Cloudy";
            Commons["CM"] = "cm";
            Commons["COLOR"] = "Color";
            Commons["COLOR_SEQUENTIAL"] = "Color sequential area sensor";
            Commons["COLOR_SEQUENTIAL_LINEAR"] = "Color sequential linear sensor";
            Commons["CONTINUOUS"] = "Continuous";
            Commons["CONTRAST_M"] = "Contrast -";
            Commons["CONTRAST_P"] = "Contrast +";
            Commons["CUSTOM"] = "Custom";
            Commons["CUSTOM_WHITE_BALANCE"] = "Custom white balance";
            Commons["D55"] = "D55";
            Commons["D65"] = "D65";
            Commons["D75"] = "D75";
            Commons["DATUM_POINT"] = "Datum point";
            Commons["DAYLIGHT"] = "Daylight";
            Commons["DAYLIGHTCOLOR_FLUORESCENCE"] = "DaylightColor-fluorescence";
            Commons["DAYWHITECOLOR_FLUORESCENCE"] = "DaywhiteColor-fluorescence";
            Commons["DEGREES"] = "{0} degrees";
            Commons["DIGITAL_2X_ZOOM"] = "Digital 2x Zoom";
            Commons["DIGITAL_STILL_CAMERA"] = "Digital Still Camera (DSC)";
            Commons["DIGITAL_ZOOM"] = "{0}x digital zoom";
            Commons["DIMENSIONAL_MEASUREMENT"] = "{0}-dimensional measurement";
            Commons["DIRECTLY_PHOTOGRAPHED_IMAGE"] = "Directly photographed image";
            Commons["DISTANCE_MM"] = "{0} mm";
            Commons["DOTS_PER"] = "{0} dots per {1}";
            Commons["EASY_SHOOTING"] = "Easy shooting";
            Commons["ECONOMY"] = "Economy";
            Commons["EVALUATIVE"] = "Evaluative";
            Commons["EXTERNAL_E_TTL"] = "External E-TTL";
            Commons["EXTERNAL_FLASH"] = "Extenal flash";
            Commons["FAST_PICTURE_TAKING_MODE"] = "Fast picture taking mode";
            Commons["FAST_SHUTTER"] = "Fast shutter";
            Commons["FINE"] = "Fine";
            Commons["FISHEYE_CONVERTER"] = "Fisheye converter";
            Commons["FLASH"] = "Flash";
            Commons["FLASH_BIAS_N_033"] = "-0.33 EV";
            Commons["FLASH_BIAS_N_050"] = "-0.50 EV";
            Commons["FLASH_BIAS_N_067"] = "-0.67 EV";
            Commons["FLASH_BIAS_N_133"] = "-1.33 EV";
            Commons["FLASH_BIAS_N_150"] = "-1.50 EV";
            Commons["FLASH_BIAS_N_167"] = "-1.67 EV";
            Commons["FLASH_BIAS_N_1"] = "-1 EV";
            Commons["FLASH_BIAS_N_2"] = "-2 EV";
            Commons["FLASH_BIAS_P_033"] = "0.33 EV";
            Commons["FLASH_BIAS_P_050"] = "0.50 EV";
            Commons["FLASH_BIAS_P_067"] = "0.67 EV";
            Commons["FLASH_BIAS_P_0"] = "0 EV";
            Commons["FLASH_BIAS_P_133"] = "1.33 EV";
            Commons["FLASH_BIAS_P_150"] = "1.50 EV";
            Commons["FLASH_BIAS_P_167"] = "1.67 EV";
            Commons["FLASH_BIAS_P_1"] = "1 EV";
            Commons["FLASH_BIAS_P_2"] = "2 EV";
            Commons["FLASH_FIRED"] = "Flash fired";
            Commons["FLASH_FIRED_LIGHT_DETECTED"] = "Flash fired and strobe return light detected";
            Commons["FLASH_FIRED_LIGHT_NOT_DETECTED"] = "Flash fired but strobe return light not detected";
            Commons["FLASH_STRENGTH"] = "{0} eV (Apex)";
            Commons["FLOURESCENT"] = "Flourescent";
            Commons["FOCAL_LENGTH"] = "{0} {1}";
            Commons["FOCAL_PLANE"] = "{0} {1}";
            Commons["FP_SYNC_ENABLED"] = "FP sync enabled";
            Commons["FP_SYNC_USED"] = "FP sync used";
            Commons["FULL_AUTO"] = "Full auto";
            Commons["GPS_TIME_STAMP"] = "{0}:{1}:{2} UTC";
            Commons["HARD"] = "Hard";
            Commons["HIGH"] = "High";
            Commons["HIGH_HARD"] = "High (HARD)";
            Commons["HOURS_MINUTES_SECONDS"] = "{0}\"{1}'{2}";
            Commons["HQ"] = "HQ";
            Commons["INCANDENSCENSE"] = "Incandenscense";
            Commons["INCANDESCENSE"] = "Incandescense";
            Commons["INCHES"] = "Inches";
            Commons["INFINITE"] = "Infinite";
            Commons["INFINITY"] = "Infinity";
            Commons["INTERNAL_FLASH"] = "Internal flash";
            Commons["ISO"] = "ISO{0}";
            Commons["ISO_100"] = "100";
            Commons["ISO_1600"] = "1600";
            Commons["ISO_200"] = "200";
            Commons["ISO_400"] = "400";
            Commons["ISO_50"] = "50";
            Commons["ISO_800"] = "800";
            Commons["ISO_NOT_SPECIFIED"] = "Not specified (see ISOSpeedRatings tag)";
            Commons["JPEG_COMPRESSION"] = "JPEG compression";
            Commons["KILOMETERS"] = "kilometers";
            Commons["KNOTS"] = "knots";
            Commons["KPH"] = "kph";
            Commons["LANDSCAPE"] = "Landscape";
            Commons["LANDSCAPE_MODE"] = "Landscape mode";
            Commons["LANDSCAPE_SCENE"] = "Landscape scene";
            Commons["LARGE"] = "Large";
            Commons["LEFT"] = "Left";
            Commons["LEFT_SIDE_BOTTOM"] = "left side, bottom";
            Commons["LEFT_SIDE_TOP"] = "left side, top";
            Commons["LEFT_TO_RIGHT_PAN_DIR"] = "Left to right panorama direction";
            Commons["LENS"] = "{0}-{1}mm f/{2}-{3}";
            Commons["LOW"] = "Low";
            Commons["LOW_ORG"] = "Low (ORG)";
            Commons["MACRO"] = "Macro";
            Commons["MACRO_CLOSEUP"] = "Macro / Closeup";
            Commons["MAGNETIC_DIRECTION"] = "Magnetic direction";
            Commons["MANUAL"] = "Manual";
            Commons["MANUAL_CONTROL"] = "Manual control";
            Commons["MANUAL_EXPOSURE"] = "Manual exposure";
            Commons["MANUAL_FOCUS"] = "Manual focus";
            Commons["MEASUREMENT_INTEROPERABILITY"] = "Measurement Interoperability";
            Commons["MEASUREMENT_IN_PROGESS"] = "Measurement in progess";
            Commons["MEDIUM"] = "Medium";
            Commons["METRES"] = "{0} metres";
            Commons["MF"] = "MF";
            Commons["MILES"] = "miles";
            Commons["MODE_I_SRGB"] = "Mode I (sRGB)";
            Commons["MONOCHROME"] = "Monochrome";
            Commons["MPH"] = "mph";
            Commons["MULTI_SEGMENT"] = "Multi-segment";
            Commons["MULTI_SPOT"] = "Multi-spot";
            Commons["NIGHT"] = "Night";
            Commons["NIGHT_SCENE"] = "Night scene";
            Commons["NONE"] = "None";
            Commons["NONE_MF"] = "None (MF)";
            Commons["NORMAL"] = "Normal";
            Commons["NORMAL_NO_MACRO"] = "Normal (no macro)";
            Commons["NORMAL_PICTURE_TAKING_MODE"] = "Normal picture taking mode";
            Commons["NORMAL_STD"] = "Normal (STD)";
            Commons["NOT_DEFINED"] = "(Not defined)";
            Commons["NO_BLUR_WARNING"] = "No blur warning";
            Commons["NO_COMPRESSION"] = "No compression";
            Commons["NO_DIGITAL_ZOOM"] = "No digital zoom";
            Commons["NO_FLASH_FIRED"] = "No flash fired";
            Commons["NO_UNIT"] = "(No unit)";
            Commons["OFF"] = "Off";
            Commons["ON"] = "On";
            Commons["ONE_CHIP_COLOR"] = "One-chip color area sensor";
            Commons["ONE_SHOT"] = "One-shot";
            Commons["ON_AND_RED_YEY_REDUCTION"] = "On and red-eye reduction";
            Commons["OTHER"] = "(Other)";
            Commons["OUT_OF_FOCUS"] = "Out of focus";
            Commons["OVER_EXPOSED"] = "Over exposed (>1/1000s @ F11)";
            Commons["PANORAMA"] = "Panorama";
            Commons["PANORAMA_PICTURE_TAKING_MODE"] = "Panorama picture taking mode";
            Commons["PAN_FOCUS"] = "Pan focus";
            Commons["PARTIAL"] = "Partial";
            Commons["PIXELS"] = "{0} pixels";
            Commons["PORTRAIT"] = "Portrait";
            Commons["PORTRAIT_MODE"] = "Portrait mode";
            Commons["PORTRAIT_SCENE"] = "Portrait scene";
            Commons["POS"] = "[{0} {1} {2}] [{3} {4} {5}]";
            Commons["PRESET"] = "PreSet";
            Commons["PROGRAM"] = "Program";
            Commons["PROGRAM_ACTION"] = "Program action (high-speed program)";
            Commons["PROGRAM_AE"] = "Program AE";
            Commons["PROGRAM_CREATIVE"] = "Program creative (slow program)";
            Commons["PROGRAM_NORMAL"] = "Program normal";
            Commons["RECOMMENDED_EXIF_INTEROPERABILITY"] = "Recommended Exif Interoperability Rules (ExifR98)";
            Commons["RED_YEY_REDUCTION"] = "Red-eye reduction";
            Commons["RGB"] = "RGB";
            Commons["RIGHT"] = "Right";
            Commons["RIGHT_SIDE_BOTTOM"] = "right side, bottom";
            Commons["RIGHT_SIDE_TOP"] = "right side, top";
            Commons["RIGHT_TO_LEFT_PAN_DIR"] = "Right to left panorama direction";
            Commons["ROWS_STRIP"] = "{0} rows/strip";
            Commons["SAMPLES_PIXEL"] = "{0} samples/pixel";
            Commons["SEA_LEVEL"] = "Sea level";
            Commons["SEC"] = "{0} sec";
            Commons["SELF_TIMER_DELAY"] = "{0} sec";
            Commons["SELF_TIMER_DELAY_NOT_USED"] = "Self timer not used";
            Commons["SEPARATE"] = "Separate (Y-plane/Cb-plane/Cr-plane format)";
            Commons["SEPIA"] = "Sepia";
            Commons["SHADE"] = "Shade";
            Commons["SHQ"] = "SHQ";
            Commons["SHUTTER_PRIORITY"] = "Shutter priority";
            Commons["SHUTTER_PRIORITY_AE"] = "Shutter priority AE";
            Commons["SHUTTER_SPEED"] = "1/{0} sec";
            Commons["SINGLE"] = "Single";
            Commons["SINGLE_SHOT"] = "Single shot";
            Commons["SINGLE_SHOT_WITH_SELF_TIMER"] = "Single shot with self-timer";
            Commons["SINGLE_SHUTTER"] = "Single shutter";
            Commons["SLOW_SHUTTER"] = "Slow shutter";
            Commons["SLOW_SYNCHRO"] = "Slow-synchro";
            Commons["SMALL"] = "Small";
            Commons["SOFT"] = "Soft";
            Commons["SPEEDLIGHT"] = "SpeedLight";
            Commons["SPORTS"] = "Sports";
            Commons["SPORTS_SCENE"] = "Sports scene";
            Commons["SPOT"] = "Spot";
            Commons["SQ"] = "SQ";
            Commons["SRGB"] = "sRGB";
            Commons["STANDARD_LIGHT"] = "Standard light";
            Commons["STANDARD_LIGHT_B"] = "Standard light (B)";
            Commons["STANDARD_LIGHT_C"] = "Standard light (C)";
            Commons["STRONG"] = "Strong";
            Commons["SUNNY"] = "Sunny";
            Commons["SXGA_BASIC"] = "SXGA Basic";
            Commons["SXGA_FINE"] = "SXGA Fine";
            Commons["SXGA_NORMAL"] = "SXGA Normal";
            Commons["THREE_CHIP_COLOR"] = "Three-chip color area sensor";
            Commons["THUMBNAIL_BYTES"] = "[{0} bytes of thumbnail data]";
            Commons["TOP"] = "Top";
            Commons["TOP_LEFT_SIDE"] = "top, left side";
            Commons["TOP_RIGHT_SIDE"] = "top, right side";
            Commons["TOP_TO_BOTTOM_PAN_DIR"] = "Top to bottom panorama direction";
            Commons["TRILINEAR_SENSOR"] = "Trilinear sensor";
            Commons["TRUE_DIRECTION"] = "True direction";
            Commons["TUNGSTEN"] = "Tungsten";
            Commons["TV_PRIORITY"] = "Tv-priority";
            Commons["TWO_CHIP_COLOR"] = "Two-chip color area sensor";
            Commons["UNDEFINED"] = "Undefined";
            Commons["UNKNOWN"] = "Unknown (\"{0}\")";
            Commons["UNKNOWN_COLOUR_SPACE"] = "Unknown colour space";
            Commons["UNKNOWN_COMPRESSION"] = "Unknown compression";
            Commons["UNKNOWN_CONFIGURATION"] = "Unknown configuration";
            Commons["UNKNOWN_PICTURE_TAKING_MODE"] = "Unknown picture taking mode";
            Commons["UNKNOWN_PROGRAM"] = "Unknown program ({0})";
            Commons["UNKNOWN_SEQUENCE_NUMBER"] = "Unknown sequence number";
            Commons["VGA_BASIC"] = "VGA Basic";
            Commons["VGA_FINE"] = "VGA Fine";
            Commons["VGA_NORMAL"] = "VGA Normal";
            Commons["WEAK"] = "Weak";
            Commons["WHITE_FLUORESCENCE"] = "White-fluorescence";
            Commons["X_RD_IN_A_SEQUENCE"] = "{0}rd in a sequence";
            Commons["YCBCR"] = "YCbCr";
            Commons["YCBCR_420"] = "YCbCr4:2:0";
            Commons["YCBCR_422"] = "YCbCr4:2:2";

            Dictionary<string, string> Exif = new Dictionary<string, string>();
            Resources["ExifMarkernote"] = Exif;
            Exif["MARKER_NOTE_NAME"] = "Exif Makernote";
            Exif["TAG_APERTURE"] = "Aperture Value";
            Exif["TAG_ARTIST"] = "Artist";
            Exif["TAG_BATTERY_LEVEL"] = "Battery Level";
            Exif["TAG_BITS_PER_SAMPLE"] = "Bits Per Sample";
            Exif["TAG_BRIGHTNESS_VALUE"] = "Brightness Value";
            Exif["TAG_CFA_PATTERN"] = "CFA Pattern";
            Exif["TAG_CFA_PATTERN_2"] = "CFA Pattern";
            Exif["TAG_CFA_REPEAT_PATTERN_DIM"] = "CFA Repeat Pattern Dim";
            Exif["TAG_COLOR_SPACE"] = "Color Space";
            Exif["TAG_COMPONENTS_CONFIGURATION"] = "Components Configuration";
            Exif["TAG_COMPRESSION"] = "Compression";
            Exif["TAG_COMPRESSION_LEVEL"] = "Compressed Bits Per Pixel";
            Exif["TAG_COPYRIGHT"] = "Copyright";
            Exif["TAG_DATETIME"] = "Date/Time";
            Exif["TAG_DATETIME_DIGITIZED"] = "Date/Time Digitized";
            Exif["TAG_DATETIME_ORIGINAL"] = "Date/Time Original";
            Exif["TAG_DOCUMENT_NAME"] = "Document Name";
            Exif["TAG_EXIF_IMAGE_HEIGHT"] = "Exif Image Height";
            Exif["TAG_EXIF_IMAGE_WIDTH"] = "Exif Image Width";
            Exif["TAG_EXIF_OFFSET"] = "Exif Offset";
            Exif["TAG_EXIF_VERSION"] = "Exif Version";
            Exif["TAG_EXPOSURE_BIAS"] = "Exposure Bias Value";
            Exif["TAG_EXPOSURE_INDEX"] = "Exposure Index";
            Exif["TAG_EXPOSURE_INDEX_2"] = "Exposure Index";
            Exif["TAG_EXPOSURE_PROGRAM"] = "Exposure Program";
            Exif["TAG_EXPOSURE_TIME"] = "Exposure Time";
            Exif["TAG_FILE_SOURCE"] = "File Source";
            Exif["TAG_FILL_ORDER"] = "Fill Order";
            Exif["TAG_FLASH"] = "Flash";
            Exif["TAG_FLASHPIX_VERSION"] = "FlashPix Version";
            Exif["TAG_FLASH_ENERGY"] = "Flash Energy";
            Exif["TAG_FLASH_ENERGY_2"] = "Flash Energy";
            Exif["TAG_FNUMBER"] = "F-Number";
            Exif["TAG_FOCAL_LENGTH"] = "Focal Length";
            Exif["TAG_FOCAL_PLANE_UNIT"] = "Focal Plane Resolution Unit";
            Exif["TAG_FOCAL_PLANE_X_RES"] = "Focal Plane X Resolution";
            Exif["TAG_FOCAL_PLANE_Y_RES"] = "Focal Plane Y Resolution";
            Exif["TAG_GPS_INFO"] = "GPS Info";
            Exif["TAG_IMAGE_DESCRIPTION"] = "Image Description";
            Exif["TAG_IMAGE_HISTORY"] = "Image History";
            Exif["TAG_IMAGE_NUMBER"] = "Image Number";
            Exif["TAG_INTERLACE"] = "Interlace";
            Exif["TAG_INTEROPERABILITY_OFFSET"] = "Interoperability Offset";
            Exif["TAG_INTER_COLOR_PROFILE"] = "Inter Color Profile";
            Exif["TAG_IPTC_NAA"] = "IPTC/NAA";
            Exif["TAG_ISO_EQUIVALENT"] = "ISO Speed Ratings";
            Exif["TAG_JPEG_PROC"] = "JPEG Proc";
            Exif["TAG_JPEG_TABLES"] = "JPEG Tables";
            Exif["TAG_MAKE"] = "Make";
            Exif["TAG_MARKER_NOTE"] = "Maker Note";
            Exif["TAG_MAX_APERTURE"] = "Max Aperture Value";
            Exif["TAG_METERING_MODE"] = "Metering Mode";
            Exif["TAG_MODEL"] = "Model";
            Exif["TAG_NEW_SUBFILE_TYPE"] = "New Subfile Type";
            Exif["TAG_NOISE"] = "Noise";
            Exif["TAG_OECF"] = "OECF";
            Exif["TAG_ORIENTATION"] = "Orientation";
            Exif["TAG_PHOTOMETRIC_INTERPRETATION"] = "Photometric Interpretation";
            Exif["TAG_PLANAR_CONFIGURATION"] = "Planar Configuration";
            Exif["TAG_PREDICTOR"] = "Predictor";
            Exif["TAG_PRIMARY_CHROMATICITIES"] = "Primary Chromaticities";
            Exif["TAG_REFERENCE_BLACK_WHITE"] = "Reference Black/White";
            Exif["TAG_RELATED_IMAGE_FILE_FORMAT"] = "Related Image File Format";
            Exif["TAG_RELATED_IMAGE_LENGTH"] = "Related Image Length";
            Exif["TAG_RELATED_IMAGE_WIDTH"] = "Related Image Width";
            Exif["TAG_RELATED_SOUND_FILE"] = "Related Sound File";
            Exif["TAG_RESOLUTION_UNIT"] = "Resolution Unit";
            Exif["TAG_ROWS_PER_STRIP"] = "Rows Per Strip";
            Exif["TAG_SAMPLES_PER_PIXEL"] = "Samples Per Pixel";
            Exif["TAG_SCENE_TYPE"] = "Scene Type";
            Exif["TAG_SECURITY_CLASSIFICATION"] = "Security Classification";
            Exif["TAG_SELF_TIMER_MODE"] = "Self Timer Mode";
            Exif["TAG_SENSING_METHOD"] = "Sensing Method";
            Exif["TAG_SHUTTER_SPEED"] = "Shutter Speed Value";
            Exif["TAG_SOFTWARE"] = "Software";
            Exif["TAG_SPATIAL_FREQ_RESPONSE"] = "Spatial Frequency Response";
            Exif["TAG_SPATIAL_FREQ_RESPONSE_2"] = "Spatial Frequency Response";
            Exif["TAG_SPECTRAL_SENSITIVITY"] = "Spectral Sensitivity";
            Exif["TAG_STRIP_BYTE_COUNTS"] = "Strip Byte Counts";
            Exif["TAG_STRIP_OFFSETS"] = "Strip Offsets";
            Exif["TAG_SUBFILE_TYPE"] = "Subfile Type";
            Exif["TAG_SUBJECT_DISTANCE"] = "Subject Distance";
            Exif["TAG_SUBJECT_LOCATION"] = "Subject Location";
            Exif["TAG_SUBJECT_LOCATION_2"] = "Subject Location";
            Exif["TAG_SUBSECOND_TIME"] = "Sub-Sec Time";
            Exif["TAG_SUBSECOND_TIME_DIGITIZED"] = "Sub-Sec Time Digitized";
            Exif["TAG_SUBSECOND_TIME_ORIGINAL"] = "Sub-Sec Time Original";
            Exif["TAG_SUB_IFDS"] = "Sub IFDs";
            Exif["TAG_THUMBNAIL_DATA"] = "Thumbnail Data";
            Exif["TAG_THUMBNAIL_IMAGE_HEIGHT"] = "Thumbnail Image Height";
            Exif["TAG_THUMBNAIL_IMAGE_WIDTH"] = "Thumbnail Image Width";
            Exif["TAG_THUMBNAIL_LENGTH"] = "Thumbnail Length";
            Exif["TAG_THUMBNAIL_OFFSET"] = "Thumbnail Offset";
            Exif["TAG_TIFF_EP_STANDARD_ID"] = "TIFF/EP Standard ID";
            Exif["TAG_TILE_BYTE_COUNTS"] = "Tile Byte Counts";
            Exif["TAG_TILE_LENGTH"] = "Tile Length";
            Exif["TAG_TILE_OFFSETS"] = "Tile Offsets";
            Exif["TAG_TILE_WIDTH"] = "Tile Width";
            Exif["TAG_TIME_ZONE_OFFSET"] = "Time Zone Offset";
            Exif["TAG_TRANSFER_FUNCTION"] = "Transfer Function";
            Exif["TAG_TRANSFER_RANGE"] = "Transfer Range";
            Exif["TAG_USER_COMMENT"] = "User Comment";
            Exif["TAG_WHITE_BALANCE"] = "Light Source";
            Exif["TAG_WHITE_POINT"] = "White Point";
            Exif["TAG_X_RESOLUTION"] = "X Resolution";
            Exif["TAG_YCBCR_COEFFICIENTS"] = "YCbCr Coefficients";
            Exif["TAG_YCBCR_POSITIONING"] = "YCbCr Positioning";
            Exif["TAG_YCBCR_SUBSAMPLING"] = "YCbCr Sub-Sampling";
            Exif["TAG_Y_RESOLUTION"] = "Y Resolution";
            Exif["TAG_XP_TITLE"] = "Title (Win)";
            Exif["TAG_XP_COMMENTS"] = "Comments (Win)";
            Exif["TAG_XP_AUTHOR"] = "Author (Win)";
            Exif["TAG_XP_KEYWORDS"] = "Keyword (Win)";
            Exif["TAG_XP_SUBJECT"] = "Subject (Win)";
            Exif["TAG_CUSTOM_RENDERED"] = "Custom Rendered";
            Exif["TAG_EXPOSURE_MODE"] = "Exposure Mode";
            Exif["TAG_DIGITAL_ZOOM_RATIO"] = "Digital Zoom Ratio";
            Exif["TAG_FOCAL_LENGTH_IN_35MM_FILM"] = "Focal Length in 35mm Film";
            Exif["TAG_SCENE_CAPTURE_TYPE"] = "Scene Capture Type";
            Exif["TAG_GAIN_CONTROL"] = "Gain Control";
            Exif["TAG_CONTRAST"] = "Contrast";
            Exif["TAG_SATURATION"] = "Saturation";
            Exif["TAG_SHARPNESS"] = "Sharpness";
            Exif["TAG_DEVICE_SETTING_DESCRIPTION"] = "Device Setting Description";
            Exif["TAG_SUBJECT_DISTANCE_RANGE"] = "Subject Distance";
            Exif["TAG_IMAGE_UNIQUE_ID"] = "Image Unique ID";

            Dictionary<string, string> ExifInterop = new Dictionary<string, string>();
            Resources["ExifInteropMarkernote"] = ExifInterop;
            ExifInterop["MARKER_NOTE_NAME"] = "Exif Interoperability Makernote";
            ExifInterop["TAG_INTEROP_INDEX"] = "Interoperability Index";
            ExifInterop["TAG_INTEROP_VERSION"] = "Interoperability Version";
            ExifInterop["TAG_RELATED_IMAGE_FILE_FORMAT"] = "Related Image File Format";
            ExifInterop["TAG_RELATED_IMAGE_LENGTH"] = "Related Image Length";
            ExifInterop["TAG_RELATED_IMAGE_WIDTH"] = "Related Image Width";

            Dictionary<string, string> Iptc = new Dictionary<string, string>();
            Resources["IptcMarkernote"] = Iptc;
            Iptc["MARKER_NOTE_NAME"] = "Iptc Makernote";
            Iptc["TAG_BY_LINE"] = "By-line";
            Iptc["TAG_BY_LINE_TITLE"] = "By-line Title";
            Iptc["TAG_CAPTION"] = "Caption/Abstract";
            Iptc["TAG_CATEGORY"] = "Category";
            Iptc["TAG_CITY"] = "City";
            Iptc["TAG_COPYRIGHT_NOTICE"] = "Copyright Notice";
            Iptc["TAG_COUNTRY_OR_PRIMARY_LOCATION"] = "Country/Primary Location";
            Iptc["TAG_CREDIT"] = "Credit";
            Iptc["TAG_DATE_CREATED"] = "Date Created";
            Iptc["TAG_HEADLINE"] = "Headline";
            Iptc["TAG_KEYWORDS"] = "Keywords";
            Iptc["TAG_OBJECT_NAME"] = "Object Name";
            Iptc["TAG_ORIGINAL_TRANSMISSION_REFERENCE"] = "Original Transmission Reference";
            Iptc["TAG_ORIGINATING_PROGRAM"] = "Originating Program";
            Iptc["TAG_PROVINCE_OR_STATE"] = "Province/State";
            Iptc["TAG_RECORD_VERSION"] = "Directory Version";
            Iptc["TAG_RELEASE_DATE"] = "Release Date";
            Iptc["TAG_RELEASE_TIME"] = "Release Time";
            Iptc["TAG_SOURCE"] = "Source";
            Iptc["TAG_SPECIAL_INSTRUCTIONS"] = "Special Instructions";
            Iptc["TAG_SUPPLEMENTAL_CATEGORIES"] = "Supplemental Category(s)";
            Iptc["TAG_TIME_CREATED"] = "Time Created";
            Iptc["TAG_URGENCY"] = "Urgency";
            Iptc["TAG_WRITER"] = "Writer/Editor";

            Dictionary<string, string> Jpeg = new Dictionary<string, string>();
            Resources["JpegMarkernote"] = Jpeg;
            Jpeg["MARKER_NOTE_NAME"] = "Jpeg Makernote";
            Jpeg["TAG_JPEG_COMMENT"] = "Jpeg Comment";
            Jpeg["TAG_JPEG_COMPONENT_DATA_1"] = "Component 1";
            Jpeg["TAG_JPEG_COMPONENT_DATA_2"] = "Component 2";
            Jpeg["TAG_JPEG_COMPONENT_DATA_3"] = "Component 3";
            Jpeg["TAG_JPEG_COMPONENT_DATA_4"] = "Component 4";
            Jpeg["TAG_JPEG_DATA_PRECISION"] = "Data Precision";
            Jpeg["TAG_JPEG_IMAGE_HEIGHT"] = "Image Height";
            Jpeg["TAG_JPEG_IMAGE_WIDTH"] = "Image Width";
            Jpeg["TAG_JPEG_NUMBER_OF_COMPONENTS"] = "Number of Components";

            Dictionary<string, string> Gps = new Dictionary<string, string>();
            Resources["GpsMarkernote"] = Gps;
            Gps["MARKER_NOTE_NAME"] = "GPS Makernote";
            Gps["TAG_GPS_ALTITUDE"] = "GPS Altitude";
            Gps["TAG_GPS_ALTITUDE_REF"] = "GPS Altitude Ref";
            Gps["TAG_GPS_DEST_BEARING"] = "GPS Dest Bearing";
            Gps["TAG_GPS_DEST_BEARING_REF"] = "GPS Dest Bearing Ref";
            Gps["TAG_GPS_DEST_DISTANCE"] = "GPS Dest Distance";
            Gps["TAG_GPS_DEST_DISTANCE_REF"] = "GPS Dest Distance Ref";
            Gps["TAG_GPS_DEST_LATITUDE"] = "GPS Dest Latitude";
            Gps["TAG_GPS_DEST_LATITUDE_REF"] = "GPS Dest Latitude Ref";
            Gps["TAG_GPS_DEST_LONGITUDE"] = "GPS Dest Longitude";
            Gps["TAG_GPS_DEST_LONGITUDE_REF"] = "GPS Dest Longitude Ref";
            Gps["TAG_GPS_DOP"] = "GPS DOP";
            Gps["TAG_GPS_IMG_DIRECTION"] = "GPS Img Direction";
            Gps["TAG_GPS_IMG_DIRECTION_REF"] = "GPS Img Direction Ref";
            Gps["TAG_GPS_LATITUDE"] = "GPS Latitude";
            Gps["TAG_GPS_LATITUDE_REF"] = "GPS Latitude Ref";
            Gps["TAG_GPS_LONGITUDE"] = "GPS Longitude";
            Gps["TAG_GPS_LONGITUDE_REF"] = "GPS Longitude Ref";
            Gps["TAG_GPS_MAP_DATUM"] = "GPS Map Datum";
            Gps["TAG_GPS_MEASURE_MODE"] = "GPS Measure Mode";
            Gps["TAG_GPS_SATELLITES"] = "GPS Satellites";
            Gps["TAG_GPS_SPEED"] = "GPS Speed";
            Gps["TAG_GPS_SPEED_REF"] = "GPS Speed Ref";
            Gps["TAG_GPS_STATUS"] = "GPS Status";
            Gps["TAG_GPS_TIME_STAMP"] = "GPS Time-Stamp";
            Gps["TAG_GPS_TRACK"] = "GPS Track";
            Gps["TAG_GPS_TRACK_REF"] = "GPS Track Ref";
            Gps["TAG_GPS_VERSION_ID"] = "GPS Version ID";

            Dictionary<string, string> Canon = new Dictionary<string, string>();
            Resources["CanonMarkernote"] = Canon;
            Canon["MARKER_NOTE_NAME"] = "Canon Makernote";
            Canon["TAG_CANON_CUSTOM_FUNCTIONS"] = "Custom Functions";
            Canon["TAG_CANON_FIRMWARE_VERSION"] = "Firmware Version";
            Canon["TAG_CANON_IMAGE_NUMBER"] = "Image Number";
            Canon["TAG_CANON_IMAGE_TYPE"] = "Image Type";
            Canon["TAG_CANON_OWNER_NAME"] = "Owner Name";
            Canon["TAG_CANON_SERIAL_NUMBER"] = "Camera Serial Number";
            Canon["TAG_CANON_STATE1_AF_POINT_SELECTED"] = "AF Point Selected";
            Canon["TAG_CANON_STATE1_CONTINUOUS_DRIVE_MODE"] = "Continuous Drive Mode";
            Canon["TAG_CANON_STATE1_CONTRAST"] = "Contrast";
            Canon["TAG_CANON_STATE1_EASY_SHOOTING_MODE"] = "Easy Shooting Mode";
            Canon["TAG_CANON_STATE1_EXPOSURE_MODE"] = "Exposure Mode";
            Canon["TAG_CANON_STATE1_FLASH_DETAILS"] = "Flash Details";
            Canon["TAG_CANON_STATE1_FLASH_MODE"] = "Flash Mode";
            Canon["TAG_CANON_STATE1_FOCAL_UNITS_PER_MM"] = "Focal Units per mm";
            Canon["TAG_CANON_STATE1_FOCUS_MODE_1"] = "Focus Mode";
            Canon["TAG_CANON_STATE1_FOCUS_MODE_2"] = "Focus Mode";
            Canon["TAG_CANON_STATE1_IMAGE_SIZE"] = "Image Size";
            Canon["TAG_CANON_STATE1_ISO"] = "Iso";
            Canon["TAG_CANON_STATE1_LONG_FOCAL_LENGTH"] = "Long Focal Length";
            Canon["TAG_CANON_STATE1_MACRO_MODE"] = "Macro Mode";
            Canon["TAG_CANON_STATE1_METERING_MODE"] = "Metering Mode";
            Canon["TAG_CANON_STATE1_SATURATION"] = "Saturation";
            Canon["TAG_CANON_STATE1_SELF_TIMER_DELAY"] = "Self Timer Delay";
            Canon["TAG_CANON_STATE1_SHARPNESS"] = "Sharpness";
            Canon["TAG_CANON_STATE1_SHORT_FOCAL_LENGTH"] = "Short Focal Length";
            Canon["TAG_CANON_STATE1_UNKNOWN_10"] = "Unknown Camera State 10";
            Canon["TAG_CANON_STATE1_UNKNOWN_11"] = "Unknown Camera State 11";
            Canon["TAG_CANON_STATE1_UNKNOWN_12"] = "Unknown Camera State 12";
            Canon["TAG_CANON_STATE1_UNKNOWN_13"] = "Unknown Camera State 13";
            Canon["TAG_CANON_STATE1_UNKNOWN_1"] = "Unknown Camera State 1";
            Canon["TAG_CANON_STATE1_UNKNOWN_2"] = "Unknown Camera State 2";
            Canon["TAG_CANON_STATE1_UNKNOWN_3"] = "Unknown Camera State 3";
            Canon["TAG_CANON_STATE1_UNKNOWN_4"] = "Unknown Camera State 4";
            Canon["TAG_CANON_STATE1_UNKNOWN_5"] = "Unknown Camera State 5";
            Canon["TAG_CANON_STATE1_UNKNOWN_6"] = "Unknown Camera State 6";
            Canon["TAG_CANON_STATE1_UNKNOWN_7"] = "Unknown Camera State 7";
            Canon["TAG_CANON_STATE1_UNKNOWN_8"] = "Unknown Camera State 8";
            Canon["TAG_CANON_STATE1_UNKNOWN_9"] = "Unknown Camera State 9";
            Canon["TAG_CANON_STATE2_AF_POINT_USED"] = "AF Point Used";
            Canon["TAG_CANON_STATE2_FLASH_BIAS"] = "Flash Bias";
            Canon["TAG_CANON_STATE2_SEQUENCE_NUMBER"] = "Sequence Number";
            Canon["TAG_CANON_STATE2_SUBJECT_DISTANCE"] = "Subject Distance";
            Canon["TAG_CANON_STATE2_WHITE_BALANCE"] = "White Balance";
            Canon["TAG_CANON_UNKNOWN_1"] = "Makernote Unknown 1";

            Dictionary<string, string> Casio = new Dictionary<string, string>();
            Resources["CasioMarkernote"] = Casio;
            Casio["MARKER_NOTE_NAME"] = "Casio Makernote";
            Casio["TAG_CASIO_CCD_SENSITIVITY"] = "CCD Sensitivity";
            Casio["TAG_CASIO_CONTRAST"] = "Contrast";
            Casio["TAG_CASIO_DIGITAL_ZOOM"] = "Digital Zoom";
            Casio["TAG_CASIO_FLASH_INTENSITY"] = "Flash Intensity";
            Casio["TAG_CASIO_FLASH_MODE"] = "Flash Mode";
            Casio["TAG_CASIO_FOCUSING_MODE"] = "Focussing Mode";
            Casio["TAG_CASIO_OBJECT_DISTANCE"] = "Object Distance";
            Casio["TAG_CASIO_QUALITY"] = "Quality";
            Casio["TAG_CASIO_RECORDING_MODE"] = "Recording Mode";
            Casio["TAG_CASIO_SATURATION"] = "Saturation";
            Casio["TAG_CASIO_SHARPNESS"] = "Sharpness";
            Casio["TAG_CASIO_UNKNOWN_1"] = "Makernote Unknown 1";
            Casio["TAG_CASIO_UNKNOWN_2"] = "Makernote Unknown 2";
            Casio["TAG_CASIO_UNKNOWN_3"] = "Makernote Unknown 3";
            Casio["TAG_CASIO_UNKNOWN_4"] = "Makernote Unknown 4";
            Casio["TAG_CASIO_UNKNOWN_5"] = "Makernote Unknown 5";
            Casio["TAG_CASIO_UNKNOWN_6"] = "Makernote Unknown 6";
            Casio["TAG_CASIO_UNKNOWN_7"] = "Makernote Unknown 7";
            Casio["TAG_CASIO_UNKNOWN_8"] = "Makernote Unknown 8";
            Casio["TAG_CASIO_WHITE_BALANCE"] = "White Balance";

            Dictionary<string, string> Fuji = new Dictionary<string, string>();
            Resources["FujiFilmMarkernote"] = Fuji;
            Fuji["MARKER_NOTE_NAME"] = "FujiFilm Makernote";
            Fuji["TAG_FUJIFILM_AE_WARNING"] = "AE Warning";
            Fuji["TAG_FUJIFILM_BLUR_WARNING"] = "Blur Warning";
            Fuji["TAG_FUJIFILM_COLOR"] = "Color";
            Fuji["TAG_FUJIFILM_CONTINUOUS_TAKING_OR_AUTO_BRACKETTING"] = "Continuous Taking Or Auto Bracketting";
            Fuji["TAG_FUJIFILM_FLASH_MODE"] = "Flash Mode";
            Fuji["TAG_FUJIFILM_FLASH_STRENGTH"] = "Flash Strength";
            Fuji["TAG_FUJIFILM_FOCUS_MODE"] = "Focus Mode";
            Fuji["TAG_FUJIFILM_FOCUS_WARNING"] = "Focus Warning";
            Fuji["TAG_FUJIFILM_MACRO"] = "Macro";
            Fuji["TAG_FUJIFILM_MAKERNOTE_VERSION"] = "Makernote Version";
            Fuji["TAG_FUJIFILM_PICTURE_MODE"] = "Picture Mode";
            Fuji["TAG_FUJIFILM_QUALITY"] = "Quality";
            Fuji["TAG_FUJIFILM_SHARPNESS"] = "Sharpness";
            Fuji["TAG_FUJIFILM_SLOW_SYNCHRO"] = "Slow Synchro";
            Fuji["TAG_FUJIFILM_TONE"] = "Tone";
            Fuji["TAG_FUJIFILM_UNKNOWN_1"] = "Makernote Unknown 1";
            Fuji["TAG_FUJIFILM_UNKNOWN_2"] = "Makernote Unknown 2";
            Fuji["TAG_FUJIFILM_WHITE_BALANCE"] = "White Balance";

            Dictionary<string, string> Nikon = new Dictionary<string, string>();
            Resources["NikonMarkernote"] = Nikon;
            Nikon["MARKER_NOTE_NAME"] = "Nikon Makernote";
            Nikon["TAG_NIKON_TYPE1_CCD_SENSITIVITY"] = "CCD Sensitivity";
            Nikon["TAG_NIKON_TYPE1_COLOR_MODE"] = "Color Mode";
            Nikon["TAG_NIKON_TYPE1_CONVERTER"] = "Fisheye Converter";
            Nikon["TAG_NIKON_TYPE1_DIGITAL_ZOOM"] = "Digital Zoom";
            Nikon["TAG_NIKON_TYPE1_FOCUS"] = "Focus";
            Nikon["TAG_NIKON_TYPE1_IMAGE_ADJUSTMENT"] = "Image Adjustment";
            Nikon["TAG_NIKON_TYPE1_QUALITY"] = "Quality";
            Nikon["TAG_NIKON_TYPE1_UNKNOWN_1"] = "Makernote Unknown 1";
            Nikon["TAG_NIKON_TYPE1_UNKNOWN_2"] = "Makernote Unknown 2";
            Nikon["TAG_NIKON_TYPE1_UNKNOWN_3"] = "Makernote Unknown 3";
            Nikon["TAG_NIKON_TYPE1_WHITE_BALANCE"] = "White Balance";
            Nikon["TAG_NIKON_TYPE2_ADAPTER"] = "Adapter";
            Nikon["TAG_NIKON_TYPE2_AF_FOCUS_POSITION"] = "AF Focus Position";
            Nikon["TAG_NIKON_TYPE2_COLOR_MODE"] = "Color Mode";
            Nikon["TAG_NIKON_TYPE2_DATA_DUMP"] = "Data Dump";
            Nikon["TAG_NIKON_TYPE2_DIGITAL_ZOOM"] = "Digital Zoom";
            Nikon["TAG_NIKON_TYPE2_FLASH_SETTING"] = "Flash Setting";
            Nikon["TAG_NIKON_TYPE2_FOCUS_MODE"] = "Focus Mode";
            Nikon["TAG_NIKON_TYPE2_IMAGE_ADJUSTMENT"] = "Image Adjustment";
            Nikon["TAG_NIKON_TYPE2_IMAGE_SHARPENING"] = "Image Sharpening";
            Nikon["TAG_NIKON_TYPE2_ISO_SELECTION"] = "ISO Selection";
            Nikon["TAG_NIKON_TYPE2_ISO_SETTING"] = "ISO Setting";
            Nikon["TAG_NIKON_TYPE2_MANUAL_FOCUS_DISTANCE"] = "Focus Distance";
            Nikon["TAG_NIKON_TYPE2_QUALITY"] = "Quality";
            Nikon["TAG_NIKON_TYPE2_UNKNOWN_1"] = "Makernote Unknown 1";
            Nikon["TAG_NIKON_TYPE2_UNKNOWN_2"] = "Makernote Unknown 2";
            Nikon["TAG_NIKON_TYPE2_WHITE_BALANCE"] = "White Balance";
            Nikon["TAG_NIKON_TYPE3_AF_TYPE"] = "AF Type";
            Nikon["TAG_NIKON_TYPE3_CAMERA_COLOR_MODE"] = "Colour Mode";
            Nikon["TAG_NIKON_TYPE3_CAMERA_HUE_ADJUSTMENT"] = "Camera Hue Adjustment";
            Nikon["TAG_NIKON_TYPE3_CAMERA_SHARPENING"] = "Sharpening";
            Nikon["TAG_NIKON_TYPE3_CAMERA_TONE_COMPENSATION"] = "Tone Compensation";
            Nikon["TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE"] = "White Balance";
            Nikon["TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_FINE"] = "White Balance Fine";
            Nikon["TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_RB_COEFF"] = "White Balance RB Coefficients";
            Nikon["TAG_NIKON_TYPE3_CAPTURE_EDITOR_DATA"] = "Capture Editor Data";
            Nikon["TAG_NIKON_TYPE3_FILE_FORMAT"] = "File Format";
            Nikon["TAG_NIKON_TYPE3_FIRMWARE_VERSION"] = "Firmware Version";
            Nikon["TAG_NIKON_TYPE3_ISO_1"] = "ISO";
            Nikon["TAG_NIKON_TYPE3_ISO_2"] = "ISO";
            Nikon["TAG_NIKON_TYPE3_LENS"] = "Lens";
            Nikon["TAG_NIKON_TYPE3_NOISE_REDUCTION"] = "Noise Reduction";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_10"] = "Unknown 10";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_11"] = "Unknown 11";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_12"] = "Unknown 12";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_13"] = "Unknown 13";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_14"] = "Unknown 14";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_15"] = "Unknown 15";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_16"] = "Unknown 16";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_17"] = "Unknown 17";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_18"] = "Unknown 18";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_19"] = "Unknown 19";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_1"] = "Unknown 01";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_20"] = "Unknown 20";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_2"] = "Unknown 02";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_3"] = "Unknown 03";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_4"] = "Unknown 04";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_5"] = "Unknown 05";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_6"] = "Unknown 06";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_7"] = "Unknown 07";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_8"] = "Unknown 08";
            Nikon["TAG_NIKON_TYPE3_UNKNOWN_9"] = "Unknown 09";

            Dictionary<string, string> Olympus = new Dictionary<string, string>();
            Resources["OlympusMarkernote"] = Olympus;
            Olympus["MARKER_NOTE_NAME"] = "Olympus Makernote";
            Olympus["TAG_OLYMPUS_CAMERA_ID"] = "Camera Id";
            Olympus["TAG_OLYMPUS_DATA_DUMP"] = "Data Dump";
            Olympus["TAG_OLYMPUS_DIGI_ZOOM_RATIO"] = "DigiZoom Ratio";
            Olympus["TAG_OLYMPUS_FIRMWARE_VERSION"] = "Firmware Version";
            Olympus["TAG_OLYMPUS_JPEG_QUALITY"] = "Jpeg Quality";
            Olympus["TAG_OLYMPUS_MACRO_MODE"] = "Macro";
            Olympus["TAG_OLYMPUS_PICT_INFO"] = "Pict Info";
            Olympus["TAG_OLYMPUS_SPECIAL_MODE"] = "Special Mode";
            Olympus["TAG_OLYMPUS_UNKNOWN_1"] = "Makernote Unknown 1";
            Olympus["TAG_OLYMPUS_UNKNOWN_2"] = "Makernote Unknown 2";
            Olympus["TAG_OLYMPUS_UNKNOWN_3"] = "Makernote Unknown 3";
        }

        private ResourceBundle()
            : base()
        {
        }

        public ResourceBundle(string aPropertyFileName)
            : base()
        {
            try
            {
                this.resourceManager = Resources[aPropertyFileName];
            }
            catch (KeyNotFoundException e)
            {
                throw new KeyNotFoundException("Key " + aPropertyFileName + " not found in the resources.", e);
            }
        }

        protected string replace(string aLine, string[] fillGapWith)
        {
            for (int i = 0; i < fillGapWith.Length; i++)
            {
                if (fillGapWith[i] == null)
                {
                    fillGapWith[i] = "";
                }
                aLine = aLine.Replace("{" + i + "}", fillGapWith[i]);
            }
            return aLine;
        }
    }

    /// <summary>
    /// Class that try to recreate some Java functionnalities.
    /// </summary>
    public sealed class Utils
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <exception cref="UnauthorizedAccessException">always</exception>
        private Utils()
        {
            throw new UnauthorizedAccessException("Do not use");
        }

        /// <summary>
        /// Builds a string from a byte array
        /// </summary>
        /// <param name="anArray">the array of byte</param>
        /// <param name="offset">where to start</param>
        /// <param name="length">the length to transform in string</param>
        /// <param name="removeSpace">if true, spaces will be avoid</param>
        /// <returns>a string representing the array of byte</returns>
        public static string Decode(byte[] anArray, int offset, int length, bool removeSpace)
        {
            StringBuilder sb = new StringBuilder(length);
            for (int i = offset; i < length + offset; i++)
            {
                char aChar = (char)anArray[i];
                if (removeSpace && (anArray[i] == 0))
                {
                    continue;
                }
                sb.Append(aChar);
            }
            return sb.ToString();
        }

        /// <summary>
        /// Builds a string from a byte array
        /// </summary>
        /// <param name="anArray">the array of byte</param>
        /// <param name="removeSpace">if true, spaces will be avoid</param>
        /// <returns>a string representing the array of byte</returns>
        public static string Decode(byte[] anArray, bool removeSpace)
        {
            return Decode(anArray, 0, anArray.Length, removeSpace);
        }

    }
}

namespace Com.Drew.Metadata
{
    [Serializable]
    public sealed class Metadata
    {
        private IDictionary directoryMap;

        /// <summary>
        /// List of Directory objects set against this object.
        /// Keeping a list handy makes creation of an Iterator and counting tags simple.
        /// </summary>
        private IList directoryList;

        /// <summary>
        /// Creates a new instance of Metadata.
        /// </summary>
        public Metadata()
            : base()
        {
            directoryMap = new Hashtable();
            directoryList = new ArrayList();
        }

        /// <summary>
        /// Creates an Iterator over the tag types set against this image, preserving the
        /// order in which they were set.  Should the same tag have been set more than once,
        /// it's first position is maintained, even though the final value is used.
        /// </summary>
        /// <returns>an Iterator of tag types set for this image</returns>
        public IEnumerator GetDirectoryIterator()
        {
            return directoryList.GetEnumerator();
        }

        /// <summary>
        /// Returns a count of unique directories in this metadata collection.
        /// </summary>
        /// <returns>the number of unique directory types set for this metadata collection</returns>
        public int GetDirectoryCount()
        {
            return directoryList.Count;
        }

        /// <summary>
        /// Gets a directory regarding its type
        /// </summary>
        /// <param name="aType">the type you are looking for</param>
        /// <returns>the directory found</returns>
        /// <exception cref="ArgumentException">if aType is not a Directory like class</exception>
        public Directory GetDirectory(Type aType)
        {
            if (!typeof(Com.Drew.Metadata.Directory).IsAssignableFrom(aType))
            {
                throw new ArgumentException("Class type passed to GetDirectory must be an implementation of com.drew.metadata.Directory");
            }

            // check if we've already issued this type of directory
            if (directoryMap.Contains(aType))
            {
                return (Directory)directoryMap[aType];
            }
            object directory;
            try
            {
                ConstructorInfo[] ci = aType.GetConstructors();
                directory = ci[0].Invoke(null);
            }
            catch (Exception e)
            {
                throw new SystemException(
                    "Cannot instantiate provided Directory type: "
                    + aType.ToString(), e);
            }
            // store the directory in case it's requested later
            directoryMap.Add(aType, directory);
            directoryList.Add(directory);

            return (Directory)directory;
        }

        /// <summary>
        /// Indicates whether a given directory type has been created in this metadata repository.
        /// Directories are created by calling getDirectory(Class).
        /// </summary>
        /// <param name="aType">the Directory type</param>
        /// <returns>true if the metadata directory has been created</returns>
        public bool ContainsDirectory(Type aType)
        {
            return directoryMap.Contains(aType);
        }
    }

    /// <summary>
    /// Base class for all Metadata directory types with supporting
    /// methods for setting and getting tag values.
    /// </summary>
    [Serializable]
    public abstract class Directory
    {
        /// <summary>
        /// Map of values hashed by type identifiers.
        /// </summary>
        protected IDictionary _tagMap;

        /// <summary>
        /// The descriptor used to interperet tag values.
        /// </summary>
        protected TagDescriptor _descriptor;

        /// <summary>
        /// A convenient list holding tag values in the order in which they were stored. This is used for creation of an iterator, and for counting the number of defined tags.
        /// </summary>
        protected IList _definedTagList;

        private IList _errorList;

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public abstract string GetName();

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected abstract IDictionary GetTagNameMap();

        /// <summary>
        /// Creates a new Directory.
        /// </summary>
        public Directory()
            : base()
        {
            _tagMap = new Hashtable();
            _definedTagList = new ArrayList();
            _errorList = new ArrayList(0);
        }

        /// <summary>
        /// Indicates whether the specified tag type has been set.
        /// </summary>
        /// <param name="tagType">the tag type to check for</param>
        /// <returns>true if a value exists for the specified tag type, false if not</returns>
        public bool ContainsTag(int tagType)
        {
            return _tagMap.Contains(tagType);
        }

        /// <summary>
        /// Returns an Iterator of Tag instances that have been set in this Directory.
        /// </summary>
        /// <returns>an Iterator of Tag instances</returns>
        public IEnumerator GetTagIterator()
        {
            return _definedTagList.GetEnumerator();
        }

        /// <summary>
        /// Returns the number of tags set in this Directory.
        /// </summary>
        /// <returns>the number of tags set in this Directory</returns>
        public int GetTagCount()
        {
            return _definedTagList.Count;
        }

        /// <summary>
        /// Sets the descriptor used to interperet tag values.
        /// </summary>
        /// <param name="aDescriptor">the descriptor used to interperet tag values</param>
        /// <exception cref="NullReferenceException">if aDescriptor is null</exception>
        public void SetDescriptor(TagDescriptor aDescriptor)
        {
            if (aDescriptor == null)
            {
                throw new NullReferenceException("cannot set a null descriptor");
            }
            _descriptor = aDescriptor;
        }

        /// <summary>
        /// Adds an error
        /// </summary>
        /// <param name="message">the error message</param>
        public void AddError(string message)
        {
            _errorList.Add(message);
        }

        /// <summary>
        /// Checks if there is error
        /// </summary>
        /// <returns>true if there is error, false otherwise</returns>
        public bool HasErrors()
        {
            return (_errorList.Count > 0);
        }

        /// <summary>
        /// Gets an enumerator upon errors
        /// </summary>
        /// <returns>en enumerator for errors</returns>
        public IEnumerator GetErrors()
        {
            return _errorList.GetEnumerator();
        }

        /// <summary>
        /// Gives the number of errors
        /// </summary>
        /// <returns>the number of errors</returns>
        public int GetErrorCount()
        {
            return _errorList.Count;
        }

        /// <summary>
        /// Sets an int array for the specified tag.
        /// </summary>
        /// <param name="tagType">the tag identifier</param>
        /// <param name="ints">the int array to store</param>
        public virtual void SetIntArray(int tagType, int[] ints)
        {
            SetObject(tagType, ints);
        }

        /// <summary>
        /// Helper method, containing common functionality for all 'add' methods.
        /// </summary>
        /// <param name="tagType">the tag's value as an int</param>
        /// <param name="aValue">the value for the specified tag</param>
        /// <exception cref="NullReferenceException">if aValue is null</exception>
        public void SetObject(int tagType, object aValue)
        {
            if (aValue == null)
            {
                throw new NullReferenceException("cannot set a null object");
            }

            if (!_tagMap.Contains(tagType))
            {
                _tagMap.Add(tagType, aValue);
                _definedTagList.Add(new Tag(tagType, this));
            }
            else
            {
                // We remove it and re-add it with the new value
                _tagMap.Remove(tagType);
                _tagMap.Add(tagType, aValue);
            }
        }

        /// <summary>
        /// Returns the specified tag's value as an int, if possible.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the specified tag's value as an int, if possible.</returns>
        /// <exception cref="MetadataException">if tag not found</exception>
        public int GetInt(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is string)
            {
                try
                {
                    return Convert.ToInt32((string)o);
                }
                catch (FormatException)
                {
                    // convert the char array to an int
                    string s = (string)o;
                    int val = 0;
                    for (int i = s.Length - 1; i >= 0; i--)
                    {
                        val += s[i] << (i * 8);
                    }
                    return val;
                }
            }
            else if (o is Rational)
            {
                return ((Rational)o).IntValue();
            }
            return (int)o;
        }

        /// <summary>
        /// Gets the specified tag's value as a string array, if possible.  Only supported where the tag is set as string[], string, int[], byte[] or Rational[].
        /// </summary>
        /// <param name="tagType">the tag identifier</param>
        /// <returns>the tag's value as an array of Strings</returns>
        /// <exception cref="MetadataException">if tag not found or if it cannot be represented as a string[]</exception>
        public string[] GetStringArray(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is string[])
            {
                return (string[])o;
            }
            else if (o is string)
            {
                string[] strings = { (string)o };
                return strings;
            }
            else if (o is int[])
            {
                int[] ints = (int[])o;
                string[] strings = new string[ints.Length];
                for (int i = 0; i < strings.Length; i++)
                {
                    strings[i] = ints[i].ToString();
                }
                return strings;
            }
            else if (o is byte[])
            {
                byte[] bytes = (byte[])o;
                string[] strings = new string[bytes.Length];
                for (int i = 0; i < strings.Length; i++)
                {
                    strings[i] = bytes[i].ToString();
                }
                return strings;
            }
            else if (o is Rational[])
            {
                Rational[] rationals = (Rational[])o;
                string[] strings = new string[rationals.Length];
                for (int i = 0; i < strings.Length; i++)
                {
                    strings[i] = rationals[i].ToSimpleString(false);
                }
                return strings;
            }
            throw new MetadataException(
                "Requested tag cannot be cast to string array ("
                + o.GetType().ToString()
                + ")");
        }

        /// <summary>
        /// Gets the specified tag's value as an int array, if possible.  Only supported where the tag is set as string, int[], byte[] or Rational[].
        /// </summary>
        /// <param name="tagType">the tag identifier</param>
        /// <returns>the tag's value as an int array</returns>
        /// <exception cref="MetadataException">if tag not found or if it cannot be represented as a int[]</exception>
        public int[] GetIntArray(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is Rational[])
            {
                Rational[] rationals = (Rational[])o;
                int[] ints = new int[rationals.Length];
                for (int i = 0; i < ints.Length; i++)
                {
                    ints[i] = rationals[i].IntValue();
                }
                return ints;
            }
            else if (o is int[])
            {
                return (int[])o;
            }
            else if (o is byte[])
            {
                byte[] bytes = (byte[])o;
                int[] ints = new int[bytes.Length];
                for (int i = 0; i < bytes.Length; i++)
                {
                    byte b = bytes[i];
                    ints[i] = b;
                }
                return ints;
            }
            else if (o is string)
            {
                string str = (string)o;
                int[] ints = new int[str.Length];
                for (int i = 0; i < str.Length; i++)
                {
                    ints[i] = str[i];
                }
                return ints;
            }
            throw new MetadataException(
                "Requested tag cannot be cast to int array ("
                + o.GetType().ToString()
                + ")");
        }

        /// <summary>
        /// Gets the specified tag's value as an byte array, if possible.  Only supported where the tag is set as string, int[], byte[] or Rational[].
        /// </summary>
        /// <param name="tagType">the tag identifier</param>
        /// <returns>the tag's value as a byte array</returns>
        /// <exception cref="MetadataException">if tag not found or if it cannot be represented as a byte[]</exception>
        public byte[] GetByteArray(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is Rational[])
            {
                Rational[] rationals = (Rational[])o;
                byte[] bytes = new byte[rationals.Length];
                for (int i = 0; i < bytes.Length; i++)
                {
                    bytes[i] = rationals[i].ByteValue();
                }
                return bytes;
            }
            else if (o is byte[])
            {
                return (byte[])o;
            }
            else if (o is int[])
            {
                int[] ints = (int[])o;
                byte[] bytes = new byte[ints.Length];
                for (int i = 0; i < ints.Length; i++)
                {
                    bytes[i] = (byte)ints[i];
                }
                return bytes;
            }
            else if (o is string)
            {
                string str = (string)o;
                byte[] bytes = new byte[str.Length];
                for (int i = 0; i < str.Length; i++)
                {
                    bytes[i] = (byte)str[i];
                }
                return bytes;
            }
            throw new MetadataException(
                "Requested tag cannot be cast to byte array ("
                + o.GetType().ToString()
                + ")");
        }

        /// <summary>
        /// Returns the specified tag's value as a double, if possible.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the specified tag's value as a double, if possible.</returns>
        public double GetDouble(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is string)
            {
                try
                {
                    return Convert.ToDouble((string)o);
                }
                catch (FormatException nfe)
                {
                    throw new MetadataException(
                        "unable to parse string " + o + " as a double",
                        nfe);
                }
            }
            else if (o is Rational)
            {
                return ((Rational)o).DoubleValue();
            }
            return (double)o;
        }

        /// <summary>
        /// Returns the specified tag's value as a float, if possible.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the specified tag's value as a float, if possible.</returns>
        public float GetFloat(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is string)
            {
                try
                {
                    return (float)Convert.ToDouble((string)o);
                }
                catch (FormatException nfe)
                {
                    throw new MetadataException(
                        "unable to parse string " + o + " as a float",
                        nfe);
                }
            }
            else if (o is Rational)
            {
                return ((Rational)o).FloatValue();
            }

            return (float)o;
        }

        /// <summary>
        /// Returns the specified tag's value as a long, if possible.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the specified tag's value as a long, if possible.</returns>
        public long GetLong(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is string)
            {
                try
                {
                    return Convert.ToInt64((string)o);
                }
                catch (FormatException nfe)
                {
                    throw new MetadataException(
                        "unable to parse string " + o + " as a long",
                        nfe);
                }
            }
            else if (o is Rational)
            {
                return ((Rational)o).LongValue();
            }

            return (long)o;
        }

        /// <summary>
        /// Returns the specified tag's value as a boolean, if possible.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the specified tag's value as a boolean, if possible.</returns>
        public bool GetBoolean(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is Boolean)
            {
                return ((Boolean)o);
            }
            else if (o is string)
            {
                try
                {
                    return Convert.ToBoolean((string)o);
                }
                catch (FormatException nfe)
                {
                    throw new MetadataException(
                        "unable to parse string " + o + " as a bool",
                        nfe);
                }
            }
            return (bool)o;
        }

        /// <summary>
        /// Returns the specified tag's value as a date, if possible.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the specified tag's value as a date, if possible.</returns>
        public DateTime GetDate(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is DateTime)
            {
                return (DateTime)o;
            }
            else if (o is string)
            {
                string dateString = (string)o;
                try
                {
                    return DateTime.ParseExact(dateString, "yyyy:MM:dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);
                }
                catch (FormatException ex)
                {
                    Console.Error.WriteLine(ex.StackTrace);
                }
            }
            throw new MetadataException("Requested tag cannot be cast to java.util.Date");
        }

        /// <summary>
        /// Returns the specified tag's value as a rational, if possible.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the specified tag's value as a rational, if possible.</returns>
        public Rational GetRational(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is Rational)
            {
                return (Rational)o;
            }
            throw new MetadataException("Requested tag cannot be cast to Rational");
        }

        /// <summary>
        /// Gets the specified tag's value as a rational array, if possible.  Only supported where the tag is set as Rational[].
        /// </summary>
        /// <param name="tagType">the tag identifier</param>
        /// <returns>the tag's value as a rational array</returns>
        /// <exception cref="MetadataException">if tag not found or if it cannot be represented as a rational[]</exception>
        public Rational[] GetRationalArray(int tagType)
        {
            object o = GetObject(tagType);
            if (o == null)
            {
                throw new MetadataException(
                    "Tag "
                    + GetTagName(tagType)
                    + " has not been set -- check using containsTag() first");
            }
            else if (o is Rational[])
            {
                return (Rational[])o;
            }
            throw new MetadataException(
                "Requested tag cannot be cast to Rational array ("
                + o.GetType().ToString()
                + ")");
        }

        /// <summary>
        /// Returns the specified tag's value as a string.
        /// This value is the 'raw' value.
        /// A more presentable decoding of this value may be obtained from the corresponding Descriptor.
        /// </summary>
        /// <param name="tagType">the specified tag type</param>
        /// <returns>the string reprensentation of the tag's value, or null if the tag hasn't been defined.</returns>
        public string GetString(int tagType)
        {

            object o = GetObject(tagType);
            if (o == null)
            {
                return null;
            }
            else if (o is Rational)
            {
                return ((Rational)o).ToSimpleString(true);
            }
            else if (o.GetType().IsArray)
            {
                string s = o.GetType().ToString();

                int arrayLength = 0;

                if (s.IndexOf("Int") != -1)
                {
                    // handle arrays of objects and primitives
                    arrayLength = ((int[])o).Length;
                }
                else if (s.IndexOf("Rational") != -1)
                {
                    arrayLength = ((Rational[])o).Length;
                }
                else if (s.IndexOf("string") != -1 || s.IndexOf("String") != -1)
                {
                    arrayLength = ((string[])o).Length;
                }

                StringBuilder sbuffer = new StringBuilder();
                for (int i = 0; i < arrayLength; i++)
                {
                    if (i != 0)
                    {
                        sbuffer.Append(' ');
                    }
                    if (s.IndexOf("Int") != -1)
                    {
                        sbuffer.Append(((int[])o)[i].ToString());
                    }
                    else if (s.IndexOf("Rational") != -1)
                    {
                        sbuffer.Append(((Rational[])o)[i].ToString());
                    }
                    else if (s.IndexOf("string") != -1 || s.IndexOf("String") != -1)
                    {
                        sbuffer.Append(((string[])o)[i].ToString());
                    }
                }
                return sbuffer.ToString();
            }
            else
            {
                return o.ToString();
            }
        }

        /// <summary>
        /// Returns the object hashed for the particular tag type specified, if available.
        /// </summary>
        /// <param name="tagType">the tag type identifier</param>
        /// <returns>the tag's value as an object if available, else null</returns>
        public object GetObject(int tagType)
        {
            return _tagMap[tagType];
        }

        /// <summary>
        /// Returns the name of a specified tag as a string.
        /// </summary>
        /// <param name="tagType">the tag type identifier</param>
        /// <returns>the tag's name as a string</returns>
        public string GetTagName(int tagType)
        {
            IDictionary nameMap = GetTagNameMap();
            if (!nameMap.Contains(tagType))
            {
                string hex = tagType.ToString("X");
                while (hex.Length < 4)
                {
                    hex = "0" + hex;
                }
                return "Unknown tag (0x" + hex + ")";
            }
            return (string)nameMap[tagType];
        }

        /// <summary>
        /// Provides a description of a tag's value using the descriptor set by setDescriptor(Descriptor).
        /// </summary>
        /// <param name="tagType">the tag type identifier</param>
        /// <returns>the tag value's description as a string</returns>
        /// <exception cref="MetadataException">if a descriptor hasn't been set, or if an error occurs during calculation of the description within the Descriptor</exception>
        public string GetDescription(int tagType)
        {
            if (_descriptor == null)
            {
                throw new MetadataException("a descriptor must be set using setDescriptor(...) before descriptions can be provided");
            }

            return _descriptor.GetDescription(tagType);
        }
    }

    /// <summary>
    /// This class represent a basic tag
    /// </summary>
    [Serializable]
    public class Tag
    {
        private int tagType;
        private Directory directory;

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="aTagType">the type of this tag</param>
        /// <param name="aDirectory">the directory of this tag</param>
        public Tag(int aTagType, Directory aDirectory)
            : base()
        {
            tagType = aTagType;
            directory = aDirectory;
        }

        /// <summary>
        /// Gets the tag type as an int
        /// </summary>
        /// <returns>the tag type as an int</returns>
        public int GetTagType()
        {
            return tagType;
        }

        /// <summary>
        /// Gets the tag type in hex notation as a string with padded leading zeroes if necessary (i.e. 0x100E).
        /// </summary>
        /// <returns>the tag type as a string in hexadecimal notation</returns>
        public string GetTagTypeHex()
        {
            string hex = tagType.ToString("X");
            while (hex.Length < 4)
                hex = "0" + hex;
            return "0x" + hex;
        }

        /// <summary>
        /// Get a description of the tag's value, considering enumerated values and units.
        /// </summary>
        /// <returns>a description of the tag's value</returns>
        public string GetDescription()
        {
            return directory.GetDescription(tagType);
        }

        /// <summary>
        /// Get the name of the tag, such as Aperture, or InteropVersion.
        /// </summary>
        /// <returns>the tag's name</returns>
        public string GetTagName()
        {
            return directory.GetTagName(tagType);
        }

        /// <summary>
        /// Get the name of the directory in which the tag exists, such as Exif, GPS or Interoperability.
        /// </summary>
        /// <returns>name of the directory in which this tag exists</returns>
        public string GetDirectoryName()
        {
            return directory.GetName();
        }

        /// <summary>
        /// A basic representation of the tag's type and value in format: FNumber - F2.8.
        /// </summary>
        /// <returns>the tag's type and value</returns>
        public override string ToString()
        {
            string description;
            try
            {
                description = GetDescription();
            }
            catch (MetadataException)
            {
                description =
                    directory.GetString(GetTagType())
                    + " (unable to formulate description)";
            }
            return "["
                + directory.GetName()
                + "] "
                + GetTagName()
                + " - "
                + description;
        }
    }

    /// <summary>
    /// This abstract class represent the mother class of all tag descriptor.
    /// </summary>
    [Serializable]
    public abstract class TagDescriptor
    {
        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("Commons");
        protected Directory _directory;

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="aDirectory">a directory</param>
        public TagDescriptor(Directory aDirectory)
            : base()
        {
            _directory = aDirectory;
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public abstract string GetDescription(int tagType);
    }

    /// <summary>
    /// This interface represents a Metadata reader object
    /// </summary>
    public interface MetadataReader
    {
        /// <summary>
        /// Extracts metadata
        /// </summary>
        /// <returns>the metadata found</returns>
        Metadata Extract();

        /// <summary>
        /// Extracts metadata
        /// </summary>
        /// <param name="metadata">where to add metadata</param>
        /// <returns>the metadata found</returns>
        Metadata Extract(Metadata metadata);
    }

    /// <summary>
    /// This class represents a Metadata exception
    /// </summary>
    public class MetadataException : CompoundException
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="message">The error message</param>
        public MetadataException(string message)
            : base(message)
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="message">The error message</param>
        /// <param name="cause">The cause of the exception</param>
        public MetadataException(string message, Exception cause)
            : base(message, cause)
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="cause">The cause of the exception</param>
        public MetadataException(Exception cause)
            : base(cause)
        {
        }
    }
}

namespace Com.Drew.Metadata.Exif
{
    /// <summary>
    /// The Exif Directory class
    /// </summary>
    public class ExifDirectory : Directory
    {
        // TODO do these tags belong in the exif directory?
        public const int TAG_SUB_IFDS = 0x014A;
        public const int TAG_GPS_INFO = 0x8825;

        /// <summary>
        /// The actual aperture value of lens when the image was taken. Unit is APEX.
        /// To convert this value to ordinary F-number (F-stop), calculate this value's power
        /// of root 2 (=1.4142). For example, if the ApertureValue is '5', F-number is 1.4142^5 = F5.6.
        /// </summary>
        public const int TAG_APERTURE = 0x9202;

        /// <summary>
        /// When image format is no compression, this value shows the number of bits
        /// per component for each pixel. Usually this value is '8,8,8'.
        /// </summary>
        public const int TAG_BITS_PER_SAMPLE = 0x0102;

        /// <summary>
        /// Shows compression method. '1' means no compression, '6' means JPEG compression.
        /// </summary>
        public const int TAG_COMPRESSION = 0x0103;

        /// <summary>
        /// Shows the color space of the image data components. '1' means monochrome,
        /// '2' means RGB, '6' means YCbCr.
        /// </summary>
        public const int TAG_PHOTOMETRIC_INTERPRETATION = 0x0106;
        public const int TAG_STRIP_OFFSETS = 0x0111;
        public const int TAG_SAMPLES_PER_PIXEL = 0x0115;
        public const int TAG_ROWS_PER_STRIP = 0x116;
        public const int TAG_STRIP_BYTE_COUNTS = 0x0117;

        /// <summary>
        /// When image format is no compression YCbCr, this value shows byte aligns of YCbCr data.
        /// If value is '1', Y/Cb/Cr value is chunky format, contiguous for each subsampling pixel.
        /// If value is '2', Y/Cb/Cr value is separated and stored to Y plane/Cb plane/Cr plane format.
        /// </summary>
        public const int TAG_PLANAR_CONFIGURATION = 0x011C;
        public const int TAG_YCBCR_SUBSAMPLING = 0x0212;
        public const int TAG_IMAGE_DESCRIPTION = 0x010E;
        public const int TAG_SOFTWARE = 0x0131;
        public const int TAG_DATETIME = 0x0132;
        public const int TAG_WHITE_POINT = 0x013E;
        public const int TAG_PRIMARY_CHROMATICITIES = 0x013F;
        public const int TAG_YCBCR_COEFFICIENTS = 0x0211;
        public const int TAG_REFERENCE_BLACK_WHITE = 0x0214;
        public const int TAG_COPYRIGHT = 0x8298;
        public const int TAG_NEW_SUBFILE_TYPE = 0x00FE;
        public const int TAG_SUBFILE_TYPE = 0x00FF;
        public const int TAG_TRANSFER_FUNCTION = 0x012D;
        public const int TAG_ARTIST = 0x013B;
        public const int TAG_PREDICTOR = 0x013D;
        public const int TAG_TILE_WIDTH = 0x0142;
        public const int TAG_TILE_LENGTH = 0x0143;
        public const int TAG_TILE_OFFSETS = 0x0144;
        public const int TAG_TILE_BYTE_COUNTS = 0x0145;
        public const int TAG_JPEG_TABLES = 0x015B;
        public const int TAG_CFA_REPEAT_PATTERN_DIM = 0x828D;

        /// <summary>
        /// There are two definitions for CFA pattern, I don't know the difference...
        /// </summary>
        public const int TAG_CFA_PATTERN_2 = 0x828E;
        public const int TAG_BATTERY_LEVEL = 0x828F;
        public const int TAG_IPTC_NAA = 0x83BB;
        public const int TAG_INTER_COLOR_PROFILE = 0x8773;
        public const int TAG_SPECTRAL_SENSITIVITY = 0x8824;
        public const int TAG_OECF = 0x8828;
        public const int TAG_INTERLACE = 0x8829;
        public const int TAG_TIME_ZONE_OFFSET = 0x882A;
        public const int TAG_SELF_TIMER_MODE = 0x882B;
        public const int TAG_FLASH_ENERGY = 0x920B;
        public const int TAG_SPATIAL_FREQ_RESPONSE = 0x920C;
        public const int TAG_NOISE = 0x920D;
        public const int TAG_IMAGE_NUMBER = 0x9211;
        public const int TAG_SECURITY_CLASSIFICATION = 0x9212;
        public const int TAG_IMAGE_HISTORY = 0x9213;
        public const int TAG_SUBJECT_LOCATION = 0x9214;

        /// <summary>
        /// There are two definitions for exposure index, I don't know the difference...
        /// </summary>
        public const int TAG_EXPOSURE_INDEX_2 = 0x9215;
        public const int TAG_TIFF_EP_STANDARD_ID = 0x9216;
        public const int TAG_FLASH_ENERGY_2 = 0xA20B;
        public const int TAG_SPATIAL_FREQ_RESPONSE_2 = 0xA20C;
        public const int TAG_SUBJECT_LOCATION_2 = 0xA214;
        public const int TAG_MAKE = 0x010F;
        public const int TAG_MODEL = 0x0110;
        public const int TAG_ORIENTATION = 0x0112;
        public const int TAG_X_RESOLUTION = 0x011A;
        public const int TAG_Y_RESOLUTION = 0x011B;
        public const int TAG_RESOLUTION_UNIT = 0x0128;
        public const int TAG_THUMBNAIL_OFFSET = 0x0201;
        public const int TAG_THUMBNAIL_LENGTH = 0x0202;
        public const int TAG_YCBCR_POSITIONING = 0x0213;

        /// <summary>
        /// Exposure time (reciprocal of shutter speed). Unit is second.
        /// </summary>
        public const int TAG_EXPOSURE_TIME = 0x829A;

        /// <summary>
        /// The actual F-number(F-stop) of lens when the image was taken.
        /// </summary>
        public const int TAG_FNUMBER = 0x829D;

        /// <summary>
        /// Exposure program that the camera used when image was taken.
        /// '1' means manual control, '2' program normal, '3' aperture priority, '4'
        /// shutter priority, '5' program creative (slow program),
        /// '6' program action (high-speed program), '7' portrait mode, '8' landscape mode.
        /// </summary>
        public const int TAG_EXPOSURE_PROGRAM = 0x8822;
        public const int TAG_ISO_EQUIVALENT = 0x8827;
        public const int TAG_EXIF_VERSION = 0x9000;
        public const int TAG_DATETIME_ORIGINAL = 0x9003;
        public const int TAG_DATETIME_DIGITIZED = 0x9004;
        public const int TAG_COMPONENTS_CONFIGURATION = 0x9101;

        /// <summary>
        /// Average (rough estimate) compression level in JPEG bits per pixel.
        /// </summary>
        public const int TAG_COMPRESSION_LEVEL = 0x9102;

        /// <summary>
        /// Shutter speed by APEX value. To convert this value to ordinary 'Shutter Speed';
        /// calculate this value's power of 2, then reciprocal. For example, if the
        /// ShutterSpeedValue is '4', shutter speed is 1/(24)=1/16 second.
        /// </summary>
        public const int TAG_SHUTTER_SPEED = 0x9201;
        public const int TAG_BRIGHTNESS_VALUE = 0x9203;
        public const int TAG_EXPOSURE_BIAS = 0x9204;

        /// <summary>
        /// Maximum aperture value of lens. You can convert to F-number by calculating
        /// power of root 2 (same process of ApertureValue:0x9202).
        /// </summary>
        public const int TAG_MAX_APERTURE = 0x9205;
        public const int TAG_SUBJECT_DISTANCE = 0x9206;

        /// <summary>
        /// Exposure metering method. '0' means unknown, '1' average, '2' center
        /// weighted average, '3' spot, '4' multi-spot, '5' multi-segment, '6' partial, '255' other.
        /// </summary>
        public const int TAG_METERING_MODE = 0x9207;

        public const int TAG_LIGHT_SOURCE = 0x9208;

        /// <summary>
        /// White balance (aka light source). '0' means unknown, '1' daylight,
        /// '2' fluorescent, '3' tungsten, '10' flash, '17' standard light A,
        /// '18' standard light B, '19' standard light C, '20' D55, '21' D65,
        /// '22' D75, '255' other.
        /// </summary>
        public const int TAG_WHITE_BALANCE = 0xA403;

        /// <summary>
        /// '0' means flash did not fire, '1' flash fired, '5' flash fired but strobe
        /// return light not detected, '7' flash fired and strobe return light detected.
        /// </summary>
        public const int TAG_FLASH = 0x9209;

        /// <summary>
        /// Focal length of lens used to take image. Unit is millimeter.
        /// </summary>
        public const int TAG_FOCAL_LENGTH = 0x920A;
        public const int TAG_USER_COMMENT = 0x9286;
        public const int TAG_SUBSECOND_TIME = 0x9290;
        public const int TAG_SUBSECOND_TIME_ORIGINAL = 0x9291;
        public const int TAG_SUBSECOND_TIME_DIGITIZED = 0x9292;
        public const int TAG_FLASHPIX_VERSION = 0xA000;

        /// <summary>
        /// Defines Color Space. DCF image must use sRGB color space so value is always '1'.
        /// If the picture uses the other color space, value is '65535':Uncalibrated.
        /// </summary>
        public const int TAG_COLOR_SPACE = 0xA001;
        public const int TAG_EXIF_IMAGE_WIDTH = 0xA002;
        public const int TAG_EXIF_IMAGE_HEIGHT = 0xA003;
        public const int TAG_RELATED_SOUND_FILE = 0xA004;
        public const int TAG_FOCAL_PLANE_X_RES = 0xA20E;
        public const int TAG_FOCAL_PLANE_Y_RES = 0xA20F;

        /// <summary>
        /// Unit of FocalPlaneXResoluton/FocalPlaneYResolution.
        /// '1' means no-unit, '2' inch, '3' centimeter.
        ///
        /// Note: Some of Fujifilm's digicam(e.g.FX2700,FX2900,Finepix4700Z/40i etc)
        /// uses value '3' so it must be 'centimeter', but it seems that they use a '8.3mm?'
        /// (1/3in.?) to their ResolutionUnit. Fuji's BUG? Finepix4900Z has been changed to
        /// use value '2' but it doesn't match to actual value also.
        /// </summary>
        public const int TAG_FOCAL_PLANE_UNIT = 0xA210;
        public const int TAG_EXPOSURE_INDEX = 0xA215;
        public const int TAG_SENSING_METHOD = 0xA217;
        public const int TAG_FILE_SOURCE = 0xA300;
        public const int TAG_SCENE_TYPE = 0xA301;
        public const int TAG_CFA_PATTERN = 0xA302;

        public const int TAG_THUMBNAIL_IMAGE_WIDTH = 0x0100;
        public const int TAG_THUMBNAIL_IMAGE_HEIGHT = 0x0101;
        public const int TAG_THUMBNAIL_DATA = 0xF001;

        // are these two exif values?
        public const int TAG_FILL_ORDER = 0x010A;
        public const int TAG_DOCUMENT_NAME = 0x010D;

        public const int TAG_RELATED_IMAGE_FILE_FORMAT = 0x1000;
        public const int TAG_RELATED_IMAGE_WIDTH = 0x1001;
        public const int TAG_RELATED_IMAGE_LENGTH = 0x1002;
        public const int TAG_TRANSFER_RANGE = 0x0156;
        public const int TAG_JPEG_PROC = 0x0200;
        public const int TAG_EXIF_OFFSET = 0x8769;
        public const int TAG_MARKER_NOTE = 0x927C;
        public const int TAG_INTEROPERABILITY_OFFSET = 0xA005;

        // Windows Attributes added/found by Ryan Patridge
        public const int TAG_XP_TITLE = 0x9C9B;
        public const int TAG_XP_COMMENTS = 0x9C9C;
        public const int TAG_XP_AUTHOR = 0x9C9D;
        public const int TAG_XP_KEYWORDS = 0x9C9E;
        public const int TAG_XP_SUBJECT = 0x9C9F;

        // Added from Peter Hiemenz idea
        public const int TAG_CUSTOM_RENDERED = 0xA401; // Custom image  processing
        public const int TAG_EXPOSURE_MODE = 0xA402;
        public const int TAG_DIGITAL_ZOOM_RATIO = 0xA404;
        public const int TAG_FOCAL_LENGTH_IN_35MM_FILM = 0xA405;
        public const int TAG_SCENE_CAPTURE_TYPE = 0xA406;
        public const int TAG_GAIN_CONTROL = 0xA407;
        public const int TAG_CONTRAST = 0xA408;
        public const int TAG_SATURATION = 0xA409;
        public const int TAG_SHARPNESS = 0xA40A;
        public const int TAG_DEVICE_SETTING_DESCRIPTION = 0xA40B;
        public const int TAG_SUBJECT_DISTANCE_RANGE = 0xA40C;
        public const int TAG_IMAGE_UNIQUE_ID = 0xA420;


        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("ExifMarkernote");
        protected static readonly IDictionary tagNameMap = ExifDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();

            resu.Add(TAG_RELATED_IMAGE_FILE_FORMAT, BUNDLE["TAG_RELATED_IMAGE_FILE_FORMAT"]);
            resu.Add(TAG_RELATED_IMAGE_WIDTH, BUNDLE["TAG_RELATED_IMAGE_WIDTH"]);
            resu.Add(TAG_RELATED_IMAGE_LENGTH, BUNDLE["TAG_RELATED_IMAGE_LENGTH"]);
            resu.Add(TAG_TRANSFER_RANGE, BUNDLE["TAG_TRANSFER_RANGE"]);
            resu.Add(TAG_JPEG_PROC, BUNDLE["TAG_JPEG_PROC"]);
            resu.Add(TAG_EXIF_OFFSET, BUNDLE["TAG_EXIF_OFFSET"]);
            resu.Add(TAG_MARKER_NOTE, BUNDLE["TAG_MARKER_NOTE"]);
            resu.Add(TAG_INTEROPERABILITY_OFFSET, BUNDLE["TAG_INTEROPERABILITY_OFFSET"]);
            resu.Add(TAG_FILL_ORDER, BUNDLE["TAG_FILL_ORDER"]);
            resu.Add(TAG_DOCUMENT_NAME, BUNDLE["TAG_DOCUMENT_NAME"]);
            resu.Add(TAG_COMPRESSION_LEVEL, BUNDLE["TAG_COMPRESSION_LEVEL"]);
            resu.Add(TAG_NEW_SUBFILE_TYPE, BUNDLE["TAG_NEW_SUBFILE_TYPE"]);
            resu.Add(TAG_SUBFILE_TYPE, BUNDLE["TAG_SUBFILE_TYPE"]);
            resu.Add(TAG_THUMBNAIL_IMAGE_WIDTH, BUNDLE["TAG_THUMBNAIL_IMAGE_WIDTH"]);
            resu.Add(TAG_THUMBNAIL_IMAGE_HEIGHT, BUNDLE["TAG_THUMBNAIL_IMAGE_HEIGHT"]);
            resu.Add(TAG_BITS_PER_SAMPLE, BUNDLE["TAG_BITS_PER_SAMPLE"]);
            resu.Add(TAG_COMPRESSION, BUNDLE["TAG_COMPRESSION"]);
            resu.Add(TAG_PHOTOMETRIC_INTERPRETATION, BUNDLE["TAG_PHOTOMETRIC_INTERPRETATION"]);
            resu.Add(TAG_IMAGE_DESCRIPTION, BUNDLE["TAG_IMAGE_DESCRIPTION"]);
            resu.Add(TAG_MAKE, BUNDLE["TAG_MAKE"]);
            resu.Add(TAG_MODEL, BUNDLE["TAG_MODEL"]);
            resu.Add(TAG_STRIP_OFFSETS, BUNDLE["TAG_STRIP_OFFSETS"]);
            resu.Add(TAG_ORIENTATION, BUNDLE["TAG_ORIENTATION"]);
            resu.Add(TAG_SAMPLES_PER_PIXEL, BUNDLE["TAG_SAMPLES_PER_PIXEL"]);
            resu.Add(TAG_ROWS_PER_STRIP, BUNDLE["TAG_ROWS_PER_STRIP"]);
            resu.Add(TAG_STRIP_BYTE_COUNTS, BUNDLE["TAG_STRIP_BYTE_COUNTS"]);
            resu.Add(TAG_X_RESOLUTION, BUNDLE["TAG_X_RESOLUTION"]);
            resu.Add(TAG_Y_RESOLUTION, BUNDLE["TAG_Y_RESOLUTION"]);
            resu.Add(TAG_PLANAR_CONFIGURATION, BUNDLE["TAG_PLANAR_CONFIGURATION"]);
            resu.Add(TAG_RESOLUTION_UNIT, BUNDLE["TAG_RESOLUTION_UNIT"]);
            resu.Add(TAG_TRANSFER_FUNCTION, BUNDLE["TAG_TRANSFER_FUNCTION"]);
            resu.Add(TAG_SOFTWARE, BUNDLE["TAG_SOFTWARE"]);
            resu.Add(TAG_DATETIME, BUNDLE["TAG_DATETIME"]);
            resu.Add(TAG_ARTIST, BUNDLE["TAG_ARTIST"]);
            resu.Add(TAG_PREDICTOR, BUNDLE["TAG_PREDICTOR"]);
            resu.Add(TAG_WHITE_POINT, BUNDLE["TAG_WHITE_POINT"]);
            resu.Add(TAG_PRIMARY_CHROMATICITIES, BUNDLE["TAG_PRIMARY_CHROMATICITIES"]);
            resu.Add(TAG_TILE_WIDTH, BUNDLE["TAG_TILE_WIDTH"]);
            resu.Add(TAG_TILE_LENGTH, BUNDLE["TAG_TILE_LENGTH"]);
            resu.Add(TAG_TILE_OFFSETS, BUNDLE["TAG_TILE_OFFSETS"]);
            resu.Add(TAG_TILE_BYTE_COUNTS, BUNDLE["TAG_TILE_BYTE_COUNTS"]);
            resu.Add(TAG_SUB_IFDS, BUNDLE["TAG_SUB_IFDS"]);
            resu.Add(TAG_JPEG_TABLES, BUNDLE["TAG_JPEG_TABLES"]);
            resu.Add(TAG_THUMBNAIL_OFFSET, BUNDLE["TAG_THUMBNAIL_OFFSET"]);
            resu.Add(TAG_THUMBNAIL_LENGTH, BUNDLE["TAG_THUMBNAIL_LENGTH"]);
            resu.Add(TAG_THUMBNAIL_DATA, BUNDLE["TAG_THUMBNAIL_DATA"]);
            resu.Add(TAG_YCBCR_COEFFICIENTS, BUNDLE["TAG_YCBCR_COEFFICIENTS"]);
            resu.Add(TAG_YCBCR_SUBSAMPLING, BUNDLE["TAG_YCBCR_SUBSAMPLING"]);
            resu.Add(TAG_YCBCR_POSITIONING, BUNDLE["TAG_YCBCR_POSITIONING"]);
            resu.Add(TAG_REFERENCE_BLACK_WHITE, BUNDLE["TAG_REFERENCE_BLACK_WHITE"]);
            resu.Add(TAG_CFA_REPEAT_PATTERN_DIM, BUNDLE["TAG_CFA_REPEAT_PATTERN_DIM"]);
            resu.Add(TAG_CFA_PATTERN_2, BUNDLE["TAG_CFA_PATTERN_2"]);
            resu.Add(TAG_BATTERY_LEVEL, BUNDLE["TAG_BATTERY_LEVEL"]);
            resu.Add(TAG_COPYRIGHT, BUNDLE["TAG_COPYRIGHT"]);
            resu.Add(TAG_EXPOSURE_TIME, BUNDLE["TAG_EXPOSURE_TIME"]);
            resu.Add(TAG_FNUMBER, BUNDLE["TAG_FNUMBER"]);
            resu.Add(TAG_IPTC_NAA, BUNDLE["TAG_IPTC_NAA"]);
            resu.Add(TAG_INTER_COLOR_PROFILE, BUNDLE["TAG_INTER_COLOR_PROFILE"]);
            resu.Add(TAG_EXPOSURE_PROGRAM, BUNDLE["TAG_EXPOSURE_PROGRAM"]);
            resu.Add(TAG_SPECTRAL_SENSITIVITY, BUNDLE["TAG_SPECTRAL_SENSITIVITY"]);
            resu.Add(TAG_GPS_INFO, BUNDLE["TAG_GPS_INFO"]);
            resu.Add(TAG_ISO_EQUIVALENT, BUNDLE["TAG_ISO_EQUIVALENT"]);
            resu.Add(TAG_OECF, BUNDLE["TAG_OECF"]);
            resu.Add(TAG_INTERLACE, BUNDLE["TAG_INTERLACE"]);
            resu.Add(TAG_TIME_ZONE_OFFSET, BUNDLE["TAG_TIME_ZONE_OFFSET"]);
            resu.Add(TAG_SELF_TIMER_MODE, BUNDLE["TAG_SELF_TIMER_MODE"]);
            resu.Add(TAG_EXIF_VERSION, BUNDLE["TAG_EXIF_VERSION"]);
            resu.Add(TAG_DATETIME_ORIGINAL, BUNDLE["TAG_DATETIME_ORIGINAL"]);
            resu.Add(TAG_DATETIME_DIGITIZED, BUNDLE["TAG_DATETIME_DIGITIZED"]);
            resu.Add(TAG_COMPONENTS_CONFIGURATION, BUNDLE["TAG_COMPONENTS_CONFIGURATION"]);
            resu.Add(TAG_SHUTTER_SPEED, BUNDLE["TAG_SHUTTER_SPEED"]);
            resu.Add(TAG_APERTURE, BUNDLE["TAG_APERTURE"]);
            resu.Add(TAG_BRIGHTNESS_VALUE, BUNDLE["TAG_BRIGHTNESS_VALUE"]);
            resu.Add(TAG_EXPOSURE_BIAS, BUNDLE["TAG_EXPOSURE_BIAS"]);
            resu.Add(TAG_MAX_APERTURE, BUNDLE["TAG_MAX_APERTURE"]);
            resu.Add(TAG_SUBJECT_DISTANCE, BUNDLE["TAG_SUBJECT_DISTANCE"]);
            resu.Add(TAG_METERING_MODE, BUNDLE["TAG_METERING_MODE"]);
            resu.Add(TAG_WHITE_BALANCE, BUNDLE["TAG_WHITE_BALANCE"]);
            resu.Add(TAG_FLASH, BUNDLE["TAG_FLASH"]);
            resu.Add(TAG_FOCAL_LENGTH, BUNDLE["TAG_FOCAL_LENGTH"]);
            resu.Add(TAG_FLASH_ENERGY, BUNDLE["TAG_FLASH_ENERGY"]);
            resu.Add(TAG_SPATIAL_FREQ_RESPONSE, BUNDLE["TAG_SPATIAL_FREQ_RESPONSE"]);
            resu.Add(TAG_NOISE, BUNDLE["TAG_NOISE"]);
            resu.Add(TAG_IMAGE_NUMBER, BUNDLE["TAG_IMAGE_NUMBER"]);
            resu.Add(TAG_SECURITY_CLASSIFICATION, BUNDLE["TAG_SECURITY_CLASSIFICATION"]);
            resu.Add(TAG_IMAGE_HISTORY, BUNDLE["TAG_IMAGE_HISTORY"]);
            resu.Add(TAG_SUBJECT_LOCATION, BUNDLE["TAG_SUBJECT_LOCATION"]);
            resu.Add(TAG_EXPOSURE_INDEX, BUNDLE["TAG_EXPOSURE_INDEX"]);
            resu.Add(TAG_TIFF_EP_STANDARD_ID, BUNDLE["TAG_TIFF_EP_STANDARD_ID"]);
            resu.Add(TAG_USER_COMMENT, BUNDLE["TAG_USER_COMMENT"]);
            resu.Add(TAG_SUBSECOND_TIME, BUNDLE["TAG_SUBSECOND_TIME"]);
            resu.Add(TAG_SUBSECOND_TIME_ORIGINAL, BUNDLE["TAG_SUBSECOND_TIME_ORIGINAL"]);
            resu.Add(TAG_SUBSECOND_TIME_DIGITIZED, BUNDLE["TAG_SUBSECOND_TIME_DIGITIZED"]);
            resu.Add(TAG_FLASHPIX_VERSION, BUNDLE["TAG_FLASHPIX_VERSION"]);
            resu.Add(TAG_COLOR_SPACE, BUNDLE["TAG_COLOR_SPACE"]);
            resu.Add(TAG_EXIF_IMAGE_WIDTH, BUNDLE["TAG_EXIF_IMAGE_WIDTH"]);
            resu.Add(TAG_EXIF_IMAGE_HEIGHT, BUNDLE["TAG_EXIF_IMAGE_HEIGHT"]);
            resu.Add(TAG_RELATED_SOUND_FILE, BUNDLE["TAG_RELATED_SOUND_FILE"]);
            // 0x920B in TIFF/EP
            resu.Add(TAG_FLASH_ENERGY_2, BUNDLE["TAG_FLASH_ENERGY_2"]);
            // 0x920C in TIFF/EP
            resu.Add(TAG_SPATIAL_FREQ_RESPONSE_2, BUNDLE["TAG_SPATIAL_FREQ_RESPONSE_2"]);
            // 0x920E in TIFF/EP
            resu.Add(TAG_FOCAL_PLANE_X_RES, BUNDLE["TAG_FOCAL_PLANE_X_RES"]);
            // 0x920F in TIFF/EP
            resu.Add(TAG_FOCAL_PLANE_Y_RES, BUNDLE["TAG_FOCAL_PLANE_Y_RES"]);
            // 0x9210 in TIFF/EP
            resu.Add(TAG_FOCAL_PLANE_UNIT, BUNDLE["TAG_FOCAL_PLANE_UNIT"]);
            // 0x9214 in TIFF/EP
            resu.Add(TAG_SUBJECT_LOCATION_2, BUNDLE["TAG_SUBJECT_LOCATION_2"]);
            // 0x9215 in TIFF/EP
            resu.Add(TAG_EXPOSURE_INDEX_2, BUNDLE["TAG_EXPOSURE_INDEX_2"]);
            // 0x9217 in TIFF/EP
            resu.Add(TAG_SENSING_METHOD, BUNDLE["TAG_SENSING_METHOD"]);
            resu.Add(TAG_FILE_SOURCE, BUNDLE["TAG_FILE_SOURCE"]);
            resu.Add(TAG_SCENE_TYPE, BUNDLE["TAG_SCENE_TYPE"]);
            resu.Add(TAG_CFA_PATTERN, BUNDLE["TAG_CFA_PATTERN"]);

            // Windows Attributes added/found by Ryan Patridge
            resu.Add(TAG_XP_TITLE, BUNDLE["TAG_XP_TITLE"]);
            resu.Add(TAG_XP_COMMENTS, BUNDLE["TAG_XP_COMMENTS"]);
            resu.Add(TAG_XP_AUTHOR, BUNDLE["TAG_XP_AUTHOR"]);
            resu.Add(TAG_XP_KEYWORDS, BUNDLE["TAG_XP_KEYWORDS"]);
            resu.Add(TAG_XP_SUBJECT, BUNDLE["TAG_XP_SUBJECT"]);

            // Added from Peter Hiemenz idea
            resu.Add(TAG_CUSTOM_RENDERED, BUNDLE["TAG_CUSTOM_RENDERED"]);
            resu.Add(TAG_EXPOSURE_MODE, BUNDLE["TAG_EXPOSURE_MODE"]);
            resu.Add(TAG_DIGITAL_ZOOM_RATIO, BUNDLE["TAG_DIGITAL_ZOOM_RATIO"]);
            resu.Add(TAG_FOCAL_LENGTH_IN_35MM_FILM, BUNDLE["TAG_FOCAL_LENGTH_IN_35MM_FILM"]);
            resu.Add(TAG_SCENE_CAPTURE_TYPE, BUNDLE["TAG_SCENE_CAPTURE_TYPE"]);
            resu.Add(TAG_GAIN_CONTROL, BUNDLE["TAG_GAIN_CONTROL"]);
            resu.Add(TAG_CONTRAST, BUNDLE["TAG_CONTRAST"]);
            resu.Add(TAG_SATURATION, BUNDLE["TAG_SATURATION"]);
            resu.Add(TAG_SHARPNESS, BUNDLE["TAG_SHARPNESS"]);
            resu.Add(TAG_DEVICE_SETTING_DESCRIPTION, BUNDLE["TAG_DEVICE_SETTING_DESCRIPTION"]);
            resu.Add(TAG_SUBJECT_DISTANCE_RANGE, BUNDLE["TAG_SUBJECT_DISTANCE_RANGE"]);
            resu.Add(TAG_IMAGE_UNIQUE_ID, BUNDLE["TAG_IMAGE_UNIQUE_ID"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public ExifDirectory()
            : base()
        {
            this.SetDescriptor(new ExifDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }

        /// <summary>
        /// Gets the thumbnail data.
        /// </summary>
        /// <returns>the thumbnail data or null if none</returns>
        public byte[] GetThumbnailData()
        {
            if (!ContainsThumbnail())
                return null;

            return this.GetByteArray(ExifDirectory.TAG_THUMBNAIL_DATA);
        }

        /// <summary>
        /// Writes the thumbnail in the given file
        /// </summary>
        /// <param name="filename">where to write the thumbnail</param>
        /// <exception cref="MetadataException">if there is not data in thumbnail</exception>
        public void WriteThumbnail(string filename)
        {
            byte[] data = GetThumbnailData();

            if (data == null)
            {
                throw new MetadataException("No thumbnail data exists.");
            }

            FileStream stream = null;
            try
            {
                stream = new FileStream(filename, FileMode.CreateNew);
                stream.Write(data, 0, data.Length);
            }
            finally
            {
                if (stream != null)
                    stream.Close();
            }
        }

        /// <summary>
        /// Indicates if there is thumbnail data or not
        /// </summary>
        /// <returns>true if there is thumbnail data, false if not</returns>
        public bool ContainsThumbnail()
        {
            return ContainsTag(ExifDirectory.TAG_THUMBNAIL_DATA);
        }
    }

    /// <summary>
    /// This class represents EXIF INTEROP marker note.
    /// </summary>
    public class ExifInteropDirectory : Directory
    {
        public const int TAG_INTEROP_INDEX = 0x0001;
        public const int TAG_INTEROP_VERSION = 0x0002;
        public const int TAG_RELATED_IMAGE_FILE_FORMAT = 0x1000;
        public const int TAG_RELATED_IMAGE_WIDTH = 0x1001;
        public const int TAG_RELATED_IMAGE_LENGTH = 0x1002;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("ExifInteropMarkernote");
        protected static readonly IDictionary tagNameMap = ExifInteropDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_INTEROP_INDEX, BUNDLE["TAG_INTEROP_INDEX"]);
            resu.Add(TAG_INTEROP_VERSION, BUNDLE["TAG_INTEROP_VERSION"]);
            resu.Add(TAG_RELATED_IMAGE_FILE_FORMAT, BUNDLE["TAG_RELATED_IMAGE_FILE_FORMAT"]);
            resu.Add(TAG_RELATED_IMAGE_WIDTH, BUNDLE["TAG_RELATED_IMAGE_WIDTH"]);
            resu.Add(TAG_RELATED_IMAGE_LENGTH, BUNDLE["TAG_RELATED_IMAGE_LENGTH"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public ExifInteropDirectory()
            : base()
        {
            this.SetDescriptor(new ExifInteropDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// Tag descriptor for almost every images
    /// </summary>
    public class ExifInteropDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public ExifInteropDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case ExifInteropDirectory.TAG_INTEROP_INDEX:
                    return GetInteropIndexDescription();
                case ExifInteropDirectory.TAG_INTEROP_VERSION:
                    return GetInteropVersionDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Interop Version Description.
        /// </summary>
        /// <returns>the Interop Version Description.</returns>
        private string GetInteropVersionDescription()
        {
            if (!_directory.ContainsTag(ExifInteropDirectory.TAG_INTEROP_VERSION))
                return null;
            int[] ints =
                _directory.GetIntArray(ExifInteropDirectory.TAG_INTEROP_VERSION);
            return ExifDescriptor.ConvertBytesToVersionString(ints);
        }

        /// <summary>
        /// Returns the Interop index Description.
        /// </summary>
        /// <returns>the Interop index Description.</returns>
        private string GetInteropIndexDescription()
        {
            if (!_directory.ContainsTag(ExifInteropDirectory.TAG_INTEROP_INDEX))
                return null;
            string interopIndex =
                _directory.GetString(ExifInteropDirectory.TAG_INTEROP_INDEX).Trim();
            if ("R98".Equals(interopIndex.ToUpper()))
            {
                return BUNDLE["RECOMMENDED_EXIF_INTEROPERABILITY"];
            }
            else
            {
                return BUNDLE["UNKNOWN", interopIndex.ToString()];
            }
        }
    }

    /// <summary>
    /// Extracts Exif data from a JPEG header segment, providing information about
    /// the camera/scanner/capture device (if available).
    /// Information is encapsulated in an Metadata object.
    /// </summary>
    public class ExifReader : MetadataReader
    {
        /// <summary>
        /// The JPEG segment as an array of bytes.
        /// </summary>
        private byte[] _data;

        /// <summary>
        /// Represents the native byte ordering used in the JPEG segment.
        /// If true, then we're using Motorolla ordering (Big endian), else
        /// we're using Intel ordering (Little endian).
        /// </summary>
        private bool _isMotorollaByteOrder;

        /// <summary>
        /// Bean instance to store information about the image and camera/scanner/capture device.
        /// </summary>
        private Metadata _metadata;

        /// <summary>
        /// The number of bytes used per format descriptor.
        /// </summary>
        private static readonly int[] BYTES_PER_FORMAT = { 0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8 };

        /// <summary>
        /// The number of formats known.
        /// </summary>
        private static readonly int MAX_FORMAT_CODE = 12;

        // the format enumeration
        // TODO use the new DataFormat enumeration instead of these values
        private static readonly int FMT_BYTE = 1;
        private static readonly int FMT_STRING = 2;
        private static readonly int FMT_USHORT = 3;
        private static readonly int FMT_ULONG = 4;
        private static readonly int FMT_URATIONAL = 5;
        private static readonly int FMT_SBYTE = 6;
        private static readonly int FMT_UNDEFINED = 7;
        private static readonly int FMT_SSHORT = 8;
        private static readonly int FMT_SLONG = 9;
        private static readonly int FMT_SRATIONAL = 10;
        private static readonly int FMT_SINGLE = 11;
        private static readonly int FMT_DOUBLE = 12;

        public const int TAG_EXIF_OFFSET = 0x8769;
        public const int TAG_INTEROP_OFFSET = 0xA005;
        public const int TAG_GPS_INFO_OFFSET = 0x8825;
        public const int TAG_MAKER_NOTE = 0x927C;

        // NOT READONLY
        public static int TIFF_HEADER_START_OFFSET = 6;

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="file">the file to read</param>
        public ExifReader(FileInfo file)
            : this(
            new JpegSegmentReader(file).ReadSegment(
            JpegSegmentReader.SEGMENT_APP1))
        {
        }

        /**
         * Creates an ExifReader for the given JPEG header segment.
         */

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="data">the data</param>
        public ExifReader(byte[] data)
        {
            _data = data;
        }

        /// <summary>
        /// Performs the Exif data extraction, returning a new instance of Metadata.
        /// </summary>
        /// <returns>a new instance of Metadata</returns>
        public Metadata Extract()
        {
            return Extract(new Metadata());
        }

        /// <summary>
        /// Performs the Exif data extraction, adding found values to the specified instance of Metadata.
        /// </summary>
        /// <param name="metadata">where to add meta data</param>
        /// <returns>the metadata</returns>
        public Metadata Extract(Metadata metadata)
        {
            _metadata = metadata;
            if (_data == null)
            {
                return _metadata;
            }

            // once we know there's some data, create the directory and start working on it
            Directory directory = _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.ExifDirectory));
            if (_data.Length <= 14)
            {
                directory.AddError("Exif data segment must contain at least 14 bytes");
                return _metadata;
            }
            if (!"Exif\0\0".Equals(Utils.Decode(_data, 0, 6, false)))
            {
                directory.AddError("Exif data segment doesn't begin with 'Exif'");
                return _metadata;
            }

            // this should be either "MM" or "II"
            string byteOrderIdentifier = Utils.Decode(_data, 6, 2, false);
            if (!SetByteOrder(byteOrderIdentifier))
            {
                directory.AddError("Unclear distinction between Motorola/Intel byte ordering");
                return _metadata;
            }

            // Check the next two values for correctness.
            if (Get16Bits(8) != 0x2a)
            {
                directory.AddError("Invalid Exif start - should have 0x2A at offSet 8 in Exif header");
                return _metadata;
            }

            int firstDirectoryOffSet = Get32Bits(10) + TIFF_HEADER_START_OFFSET;

            // David Ekholm sent an digital camera image that has this problem
            if (firstDirectoryOffSet >= _data.Length - 1)
            {
                directory.AddError("First exif directory offSet is beyond end of Exif data segment");
                // First directory normally starts 14 bytes in -- try it here and catch another error in the worst case
                firstDirectoryOffSet = 14;
            }

            // 0th IFD (we merge with Exif IFD)
            ProcessDirectory(directory, firstDirectoryOffSet);

            // after the extraction process, if we have the correct tags, we may be able to extract thumbnail information
            ExtractThumbnail(directory);

            return _metadata;
        }

        /// <summary>
        /// Extract Thumbnail
        /// </summary>
        /// <param name="exifDirectory">where to take the information</param>
        private void ExtractThumbnail(Directory exifDirectory)
        {
            if (!(exifDirectory is ExifDirectory))
            {
                return;
            }

            if (!exifDirectory.ContainsTag(ExifDirectory.TAG_THUMBNAIL_LENGTH)
                || !exifDirectory.ContainsTag(ExifDirectory.TAG_THUMBNAIL_OFFSET))
            {
                return;
            }

            try
            {
                int offSet =
                    exifDirectory.GetInt(ExifDirectory.TAG_THUMBNAIL_OFFSET);
                int Length =
                    exifDirectory.GetInt(ExifDirectory.TAG_THUMBNAIL_LENGTH);
                byte[] result = new byte[Length];
                for (int i = 0; i < result.Length; i++)
                {
                    result[i] = _data[TIFF_HEADER_START_OFFSET + offSet + i];
                }
                exifDirectory.SetObject(
                    ExifDirectory.TAG_THUMBNAIL_DATA,
                    result);
            }
            catch (Exception e)
            {
                exifDirectory.AddError("Unable to extract thumbnail: " + e.Message);
            }
        }

        /// <summary>
        /// Sets Motorolla byte order
        /// </summary>
        /// <param name="byteOrderIdentifier">the Motorolla byte order identifier (MM=true, II=false) </param>
        /// <returns></returns>
        private bool SetByteOrder(string byteOrderIdentifier)
        {
            if ("MM".Equals(byteOrderIdentifier))
            {
                _isMotorollaByteOrder = true;
            }
            else if ("II".Equals(byteOrderIdentifier))
            {
                _isMotorollaByteOrder = false;
            }
            else
            {
                return false;
            }
            return true;
        }

        /// <summary>
        /// Process one of the nested Tiff IFD directories.
        /// 2 bytes: number of tags for each tag
        ///     2 bytes: tag type
        ///     2 bytes: format code
        ///     4 bytes: component count
        /// </summary>
        /// <param name="directory">the directory</param>
        /// <param name="dirStartOffSet">where to start</param>
        private void ProcessDirectory(Directory directory, int dirStartOffSet)
        {
            if (dirStartOffSet >= _data.Length || dirStartOffSet < 0)
            {
                directory.AddError("Ignored directory marked to start outside data segement");
                return;
            }

            // First two bytes in the IFD are the tag count
            int dirTagCount = Get16Bits(dirStartOffSet);

            if (!isDirectoryLengthValid(dirStartOffSet))
            {
                directory.AddError("Illegally sized directory");
                return;
            }


            // Handle each tag in this directory
            for (int dirEntry = 0; dirEntry < dirTagCount; dirEntry++)
            {
                int dirEntryOffSet =
                    CalculateDirectoryEntryOffSet(dirStartOffSet, dirEntry);
                int tagType = Get16Bits(dirEntryOffSet);
                // Console.WriteLine("TagType="+tagType);
                int formatCode = Get16Bits(dirEntryOffSet + 2);
                if (formatCode < 0 || formatCode > MAX_FORMAT_CODE)
                {
                    directory.AddError("Invalid format code: " + formatCode);
                    continue;
                }

                // 4 bytes indicating number of formatCode type data for this tag
                int componentCount = Get32Bits(dirEntryOffSet + 4);
                int byteCount = componentCount * BYTES_PER_FORMAT[formatCode];
                int tagValueOffSet = CalculateTagValueOffSet(byteCount, dirEntryOffSet);
                if (tagValueOffSet < 0)
                {
                    directory.AddError("Illegal pointer offSet aValue in EXIF");
                    continue;
                }

                // Calculate the aValue as an offSet for cases where the tag represents directory
                int subdirOffSet =
                    TIFF_HEADER_START_OFFSET + Get32Bits(tagValueOffSet);

                if (tagType == TAG_EXIF_OFFSET)
                {
                    // Console.WriteLine("TagType is TAG_EXIF_OFFSET ("+tagType+")");
                    ProcessDirectory(
                        _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.ExifDirectory)),
                        subdirOffSet);
                    continue;
                }
                else if (tagType == TAG_INTEROP_OFFSET)
                {
                    // Console.WriteLine("TagType is TAG_INTEROP_OFFSET ("+tagType+")");
                    ProcessDirectory(
                        _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.ExifInteropDirectory)),
                        subdirOffSet);
                    continue;
                }
                else if (tagType == TAG_GPS_INFO_OFFSET)
                {
                    // Console.WriteLine("TagType is TAG_GPS_INFO_OFFSET ("+tagType+")");
                    ProcessDirectory(
                        _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.GpsDirectory)),
                        subdirOffSet);
                    continue;
                }
                else if (tagType == TAG_MAKER_NOTE)
                {
                    // Console.WriteLine("TagType is TAG_MAKER_NOTE ("+tagType+")");
                    ProcessMakerNote(tagValueOffSet);
                    continue;
                }
                else
                {
                    // Console.WriteLine("TagType is ???? ("+tagType+")");
                    ProcessTag(
                        directory,
                        tagType,
                        tagValueOffSet,
                        componentCount,
                        formatCode);
                }
            }
            // At the end of each IFD is an optional link to the next IFD.  This link is after
            // the 2-byte tag count, and after 12 bytes for each of these tags, hence
            int nextDirectoryOffSet =
                Get32Bits(dirStartOffSet + 2 + 12 * dirTagCount);
            if (nextDirectoryOffSet != 0)
            {
                nextDirectoryOffSet += TIFF_HEADER_START_OFFSET;
                if (nextDirectoryOffSet >= _data.Length)
                {
                    // Last 4 bytes of IFD reference another IFD with an address that is out of bounds
                    // Note this could have been caused by jhead 1.3 cropping too much
                    return;
                }
                // the next directory is of same type as this one
                ProcessDirectory(directory, nextDirectoryOffSet);
            }
        }

        /// <summary>
        /// Determine the camera model and makernote format
        /// </summary>
        /// <param name="subdirOffSet">the sub offset dir</param>
        private void ProcessMakerNote(int subdirOffSet)
        {
            // Console.WriteLine("ProcessMakerNote value="+subdirOffSet);
            // Determine the camera model and makernote format
            Directory exifDirectory = _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.ExifDirectory));
            if (exifDirectory == null)
            {
                return;
            }

            string cameraModel = exifDirectory.GetString(ExifDirectory.TAG_MAKE);
            if ("OLYMP".Equals(Utils.Decode(_data, subdirOffSet, 5, false)))
            {
                // Olympus Makernote
                ProcessDirectory(
                    _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.OlympusMakernoteDirectory)),
                    subdirOffSet + 8);
            }
            else if (
                cameraModel != null
                && cameraModel.Trim().ToUpper().StartsWith("NIKON"))
            {
                if ("Nikon".Equals(Utils.Decode(_data, subdirOffSet, 5, false)))
                {
                    // There are two scenarios here:
                    // Type 1:
                    // :0000: 4E 69 6B 6F 6E 00 01 00-05 00 02 00 02 00 06 00 Nikon...........
                    // :0010: 00 00 EC 02 00 00 03 00-03 00 01 00 00 00 06 00 ................
                    // Type 3:
                    // :0000: 4E 69 6B 6F 6E 00 02 00-00 00 4D 4D 00 2A 00 00 Nikon....MM.*...
                    // :0010: 00 08 00 1E 00 01 00 07-00 00 00 04 30 32 30 30 ............0200
                    if (_data[subdirOffSet + 6] == 1)
                    {
                        // Nikon type 1 Makernote
                        ProcessDirectory(
                            _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.NikonType1MakernoteDirectory)),
                            subdirOffSet + 8);
                    }
                    else if (_data[subdirOffSet + 6] == 2)
                    {
                        // Nikon type 3 Makernote
                        // TODO at this point we're assuming that the MM ordering is continuous
                        // with the rest of the file
                        // (this seems to be the case, but I don't have many sample images)
                        // TODO shouldn't be messing around with this static variable (not threadsafe)
                        // instead, should pass an additional offSet to the ProcessDirectory method
                        int oldHeaderStartOffSet = TIFF_HEADER_START_OFFSET;
                        TIFF_HEADER_START_OFFSET = subdirOffSet + 10;
                        ProcessDirectory(
                            _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.NikonType3MakernoteDirectory)),
                            subdirOffSet + 18);
                        TIFF_HEADER_START_OFFSET = oldHeaderStartOffSet;
                    }
                    else
                    {
                        exifDirectory.AddError(
                            "Unsupported makernote data ignored.");
                    }
                }
                else
                {
                    // Nikon type 2 Makernote
                    ProcessDirectory(
                        _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.NikonType2MakernoteDirectory)),
                        subdirOffSet);
                }
            }
            else if ("Canon".ToUpper().Equals(cameraModel.ToUpper()))
            {
                // Console.WriteLine("CanonMakernoteDirectory is found");
                // Canon Makernote
                ProcessDirectory(
                    _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.CanonMakernoteDirectory)),
                    subdirOffSet);
            }
            else if ("Casio".ToUpper().Equals(cameraModel.ToUpper()))
            {
                // Casio Makernote
                ProcessDirectory(
                    _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.CasioMakernoteDirectory)),
                    subdirOffSet);
            }
            else if (
                "FUJIFILM".Equals(Utils.Decode(_data, subdirOffSet, 8, false))
                || "Fujifilm".ToUpper().Equals(cameraModel.ToUpper()))
            {
                // Fujifile Makernote
                bool byteOrderBefore = _isMotorollaByteOrder;
                // bug in fujifilm makernote ifd means we temporarily use Intel byte ordering
                _isMotorollaByteOrder = false;
                // the 4 bytes after "FUJIFILM" in the makernote point to the start of the makernote
                // IFD, though the offSet is relative to the start of the makernote, not the TIFF
                // header (like everywhere else)
                int ifdStart = subdirOffSet + Get32Bits(subdirOffSet + 8);
                ProcessDirectory(
                    _metadata.GetDirectory(typeof(Com.Drew.Metadata.Exif.FujiFilmMakernoteDirectory)),
                    ifdStart);
                _isMotorollaByteOrder = byteOrderBefore;
            }
            else
            {
                // TODO how to store makernote data when it's not from a supported camera model?
                exifDirectory.AddError("Unsupported makernote data ignored.");
            }
        }

        /// <summary>
        /// Indicates if Directory Length is valid or not
        /// </summary>
        /// <param name="dirStartOffSet">where to start</param>
        /// <returns>true if Directory Length is valid</returns>
        private bool isDirectoryLengthValid(int dirStartOffSet)
        {
            int dirTagCount = Get16Bits(dirStartOffSet);
            int dirLength = (2 + (12 * dirTagCount) + 4);
            return !(dirLength + dirStartOffSet + TIFF_HEADER_START_OFFSET >= _data.Length);
        }

        /// <summary>
        /// Processes tag
        /// </summary>
        /// <param name="directory">the directory</param>
        /// <param name="tagType">the tag type</param>
        /// <param name="tagValueOffSet">the offset value</param>
        /// <param name="componentCount">the component count</param>
        /// <param name="formatCode">the format code</param>
        private void ProcessTag(
            Directory directory,
            int tagType,
            int tagValueOffSet,
            int componentCount,
            int formatCode)
        {
            // Directory simply stores raw values
            // The display side uses a Descriptor class per directory to turn the
            // raw values into 'pretty' descriptions
            if (formatCode == FMT_UNDEFINED || formatCode == FMT_STRING)
            {
                string s = null;
                if (tagType == ExifDirectory.TAG_USER_COMMENT)
                {
                    s =
                        ReadCommentString(
                        tagValueOffSet,
                        componentCount,
                        formatCode);
                }
                else
                {
                    s = ReadString(tagValueOffSet, componentCount);
                }
                directory.SetObject(tagType, s);
            }
            else if (formatCode == FMT_SRATIONAL || formatCode == FMT_URATIONAL)
            {
                if (componentCount == 1)
                {
                    Rational rational =
                        new Rational(
                        Get32Bits(tagValueOffSet),
                        Get32Bits(tagValueOffSet + 4));
                    directory.SetObject(tagType, rational);
                }
                else
                {
                    Rational[] rationals = new Rational[componentCount];
                    for (int i = 0; i < componentCount; i++)
                    {
                        rationals[i] =
                            new Rational(
                            Get32Bits(tagValueOffSet + (8 * i)),
                            Get32Bits(tagValueOffSet + 4 + (8 * i)));
                    }
                    directory.SetObject(tagType, rationals);
                }
            }
            else if (formatCode == FMT_SBYTE || formatCode == FMT_BYTE)
            {
                if (componentCount == 1)
                {
                    // this may need to be a byte, but I think casting to int is fine
                    int b = _data[tagValueOffSet];
                    directory.SetObject(tagType, b);
                }
                else
                {
                    int[] bytes = new int[componentCount];
                    for (int i = 0; i < componentCount; i++)
                    {
                        bytes[i] = _data[tagValueOffSet + i];
                    }
                    directory.SetIntArray(tagType, bytes);
                }
            }
            else if (formatCode == FMT_SINGLE || formatCode == FMT_DOUBLE)
            {
                if (componentCount == 1)
                {
                    int i = _data[tagValueOffSet];
                    directory.SetObject(tagType, i);
                }
                else
                {
                    int[] ints = new int[componentCount];
                    for (int i = 0; i < componentCount; i++)
                    {
                        ints[i] = _data[tagValueOffSet + i];
                    }
                    directory.SetIntArray(tagType, ints);
                }
            }
            else if (formatCode == FMT_USHORT || formatCode == FMT_SSHORT)
            {
                if (componentCount == 1)
                {
                    int i = Get16Bits(tagValueOffSet);
                    directory.SetObject(tagType, i);
                }
                else
                {
                    int[] ints = new int[componentCount];
                    for (int i = 0; i < componentCount; i++)
                    {
                        ints[i] = Get16Bits(tagValueOffSet + (i * 2));
                    }
                    directory.SetIntArray(tagType, ints);
                }
            }
            else if (formatCode == FMT_SLONG || formatCode == FMT_ULONG)
            {
                if (componentCount == 1)
                {
                    int i = Get32Bits(tagValueOffSet);
                    directory.SetObject(tagType, i);
                }
                else
                {
                    int[] ints = new int[componentCount];
                    for (int i = 0; i < componentCount; i++)
                    {
                        ints[i] = Get32Bits(tagValueOffSet + (i * 4));
                    }
                    directory.SetIntArray(tagType, ints);
                }
            }
            else
            {
                directory.AddError("unknown format code " + formatCode);
            }
        }

        /// <summary>
        /// Calculates tag value offset
        /// </summary>
        /// <param name="byteCount">the byte count</param>
        /// <param name="dirEntryOffSet">the dir entry offset</param>
        /// <returns>-1 if error, or the valus offset</returns>
        private int CalculateTagValueOffSet(int byteCount, int dirEntryOffSet)
        {
            if (byteCount > 4)
            {
                // If its bigger than 4 bytes, the dir entry contains an offSet.
                // TODO if we're reading FujiFilm makernote tags, the offSet is relative to the start of the makernote itself, not the TIFF segment
                int offSetVal = Get32Bits(dirEntryOffSet + 8);
                if (offSetVal + byteCount > _data.Length)
                {
                    // Bogus pointer offSet and / or bytecount aValue
                    return -1; // signal error
                }
                return TIFF_HEADER_START_OFFSET + offSetVal;
            }
            else
            {
                // 4 bytes or less and aValue is in the dir entry itself
                return dirEntryOffSet + 8;
            }
        }

        /// <summary>
        /// Creates a string from the _data buffer starting at the specified offSet,
        /// and ending where byte=='\0' or where Length==maxLength.
        /// </summary>
        /// <param name="offSet">the offset</param>
        /// <param name="maxLength">the max length</param>
        /// <returns>a string representing what was read</returns>
        private string ReadString(int offSet, int maxLength)
        {
            int Length = 0;
            while ((offSet + Length) < _data.Length
                && _data[offSet + Length] != '\0'
                && Length < maxLength)
            {
                Length++;
            }
            return Utils.Decode(_data, offSet, Length, false);
        }

        /// <summary>
        /// A special case of ReadString that handle Exif UserComment reading.
        /// This method is necessary as certain camere models prefix the comment string
        /// with "ASCII\0", which is all that would be returned by ReadString(...).
        /// </summary>
        /// <param name="tagValueOffSet">the tag value offset</param>
        /// <param name="componentCount">the component count</param>
        /// <param name="formatCode">the format code</param>
        /// <returns>a string</returns>
        private string ReadCommentString(
            int tagValueOffSet,
            int componentCount,
            int formatCode)
        {
            // Olympus has this padded with trailing spaces.  Remove these first.
            // ArrayIndexOutOfBoundsException bug fixed by Hendrik Wördehoff - 20 Sep 2002
            int byteCount = componentCount * BYTES_PER_FORMAT[formatCode];
            for (int i = byteCount - 1; i >= 0; i--)
            {
                if (_data[tagValueOffSet + i] == ' ')
                {
                    _data[tagValueOffSet + i] = (byte)'\0';
                }
                else
                {
                    break;
                }
            }
            // Copy the comment
            if ("ASCII".Equals(Utils.Decode(_data, tagValueOffSet, 5, false)))
            {
                for (int i = 5; i < 10; i++)
                {
                    byte b = _data[tagValueOffSet + i];
                    if (b != '\0' && b != ' ')
                    {
                        return ReadString(tagValueOffSet + i, 1999);
                    }
                }
            }
            else if ("UNICODE".Equals(Utils.Decode(_data, tagValueOffSet, 7, false)))
            {
                int start = tagValueOffSet + 7;
                for (int i = start; i < 10 + start; i++)
                {
                    byte b = _data[i];
                    if (b == 0 || (char)b == ' ')
                    {
                        continue;
                    }
                    else
                    {
                        start = i;
                        break;
                    }

                }
                int end = _data.Length;
                // TODO find a way to cut the string properly
                return Utils.Decode(_data, start, end - start, true);

            }


            // TODO implement support for UNICODE and JIS UserComment encodings..?
            return ReadString(tagValueOffSet, 1999);
        }

        /// <summary>
        /// Determine the offSet at which a given InteropArray entry begins within the specified IFD.
        /// </summary>
        /// <param name="ifdStartOffSet">the offSet at which the IFD starts</param>
        /// <param name="entryNumber">the zero-based entry number</param>
        /// <returns>the directory entry offset</returns>
        private int CalculateDirectoryEntryOffSet(
            int ifdStartOffSet,
            int entryNumber)
        {
            return (ifdStartOffSet + 2 + (12 * entryNumber));
        }

        /**
         *
         */

        /// <summary>
        /// Gets a 16 bit aValue from file's native byte order.  Between 0x0000 and 0xFFFF.
        /// </summary>
        /// <param name="offSet">the offset</param>
        /// <returns>a 16 bit int</returns>
        private int Get16Bits(int offSet)
        {
            if (offSet < 0 || offSet >= _data.Length)
            {
                throw new IndexOutOfRangeException(
                    "attempt to read data outside of exif segment (index "
                    + offSet
                    + " where max index is "
                    + (_data.Length - 1)
                    + ")");
            }
            if (_isMotorollaByteOrder)
            {
                // Motorola big first
                return (_data[offSet] << 8 & 0xFF00) | (_data[offSet + 1] & 0xFF);
            }
            else
            {
                // Intel ordering
                return (_data[offSet + 1] << 8 & 0xFF00) | (_data[offSet] & 0xFF);
            }
        }

        /// <summary>
        /// Gets a 32 bit aValue from file's native byte order.
        /// </summary>
        /// <param name="offSet">the offset</param>
        /// <returns>a 32b int</returns>
        private int Get32Bits(int offSet)
        {
            if (offSet < 0 || offSet >= _data.Length)
            {
                throw new IndexOutOfRangeException(
                    "attempt to read data outside of exif segment (index "
                    + offSet
                    + " where max index is "
                    + (_data.Length - 1)
                    + ")");
            }

            if (_isMotorollaByteOrder)
            {
                // Motorola big first
                return (int)(((uint)(_data[offSet] << 24 & 0xFF000000))
                    | ((uint)(_data[offSet + 1] << 16 & 0xFF0000))
                    | ((uint)(_data[offSet + 2] << 8 & 0xFF00))
                    | ((uint)(_data[offSet + 3] & 0xFF)));
            }
            else
            {
                // Intel ordering
                return (int)(((uint)(_data[offSet + 3] << 24 & 0xFF000000))
                    | ((uint)(_data[offSet + 2] << 16 & 0xFF0000))
                    | ((uint)(_data[offSet + 1] << 8 & 0xFF00))
                    | ((uint)(_data[offSet] & 0xFF)));
            }
        }
    }

    /// <summary>
    /// Tag descriptor for almost every images
    /// </summary>
    public class ExifDescriptor : TagDescriptor
    {
        /// <summary>
        /// Dictates whether rational values will be represented in decimal format in instances
        /// where decimal notation is elegant (such as 1/2 -> 0.5, but not 1/3).
        /// </summary>
        private readonly bool _allowDecimalRepresentationOfRationals = true;

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public ExifDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case ExifDirectory.TAG_ORIENTATION:
                    return GetOrientationDescription();
                case ExifDirectory.TAG_RESOLUTION_UNIT:
                    return GetResolutionDescription();
                case ExifDirectory.TAG_YCBCR_POSITIONING:
                    return GetYCbCrPositioningDescription();
                case ExifDirectory.TAG_EXPOSURE_TIME:
                    return GetExposureTimeDescription();
                case ExifDirectory.TAG_SHUTTER_SPEED:
                    return GetShutterSpeedDescription();
                case ExifDirectory.TAG_FNUMBER:
                    return GetFNumberDescription();
                case ExifDirectory.TAG_X_RESOLUTION:
                    return GetXResolutionDescription();
                case ExifDirectory.TAG_Y_RESOLUTION:
                    return GetYResolutionDescription();
                case ExifDirectory.TAG_THUMBNAIL_OFFSET:
                    return GetThumbnailOffSetDescription();
                case ExifDirectory.TAG_THUMBNAIL_LENGTH:
                    return GetThumbnailLengthDescription();
                case ExifDirectory.TAG_COMPRESSION_LEVEL:
                    return GetCompressionLevelDescription();
                case ExifDirectory.TAG_SUBJECT_DISTANCE:
                    return GetSubjectDistanceDescription();
                case ExifDirectory.TAG_METERING_MODE:
                    return GetMeteringModeDescription();
                case ExifDirectory.TAG_WHITE_BALANCE:
                    return GetWhiteBalanceDescription();
                case ExifDirectory.TAG_FLASH:
                    return GetFlashDescription();
                case ExifDirectory.TAG_FOCAL_LENGTH:
                    return GetFocalLengthDescription();
                case ExifDirectory.TAG_COLOR_SPACE:
                    return GetColorSpaceDescription();
                case ExifDirectory.TAG_EXIF_IMAGE_WIDTH:
                    return GetExifImageWidthDescription();
                case ExifDirectory.TAG_EXIF_IMAGE_HEIGHT:
                    return GetExifImageHeightDescription();
                case ExifDirectory.TAG_FOCAL_PLANE_UNIT:
                    return GetFocalPlaneResolutionUnitDescription();
                case ExifDirectory.TAG_FOCAL_PLANE_X_RES:
                    return GetFocalPlaneXResolutionDescription();
                case ExifDirectory.TAG_FOCAL_PLANE_Y_RES:
                    return GetFocalPlaneYResolutionDescription();
                case ExifDirectory.TAG_THUMBNAIL_IMAGE_WIDTH:
                    return GetThumbnailImageWidthDescription();
                case ExifDirectory.TAG_THUMBNAIL_IMAGE_HEIGHT:
                    return GetThumbnailImageHeightDescription();
                case ExifDirectory.TAG_BITS_PER_SAMPLE:
                    return GetBitsPerSampleDescription();
                case ExifDirectory.TAG_COMPRESSION:
                    return GetCompressionDescription();
                case ExifDirectory.TAG_PHOTOMETRIC_INTERPRETATION:
                    return GetPhotometricInterpretationDescription();
                case ExifDirectory.TAG_ROWS_PER_STRIP:
                    return GetRowsPerStripDescription();
                case ExifDirectory.TAG_STRIP_BYTE_COUNTS:
                    return GetStripByteCountsDescription();
                case ExifDirectory.TAG_SAMPLES_PER_PIXEL:
                    return GetSamplesPerPixelDescription();
                case ExifDirectory.TAG_PLANAR_CONFIGURATION:
                    return GetPlanarConfigurationDescription();
                case ExifDirectory.TAG_YCBCR_SUBSAMPLING:
                    return GetYCbCrSubsamplingDescription();
                case ExifDirectory.TAG_EXPOSURE_PROGRAM:
                    return GetExposureProgramDescription();
                case ExifDirectory.TAG_APERTURE:
                    return GetApertureValueDescription();
                case ExifDirectory.TAG_MAX_APERTURE:
                    return GetMaxApertureValueDescription();
                case ExifDirectory.TAG_SENSING_METHOD:
                    return GetSensingMethodDescription();
                case ExifDirectory.TAG_EXPOSURE_BIAS:
                    return GetExposureBiasDescription();
                case ExifDirectory.TAG_FILE_SOURCE:
                    return GetFileSourceDescription();
                case ExifDirectory.TAG_SCENE_TYPE:
                    return GetSceneTypeDescription();
                case ExifDirectory.TAG_COMPONENTS_CONFIGURATION:
                    return GetComponentConfigurationDescription();
                case ExifDirectory.TAG_EXIF_VERSION:
                    return GetExifVersionDescription();
                case ExifDirectory.TAG_FLASHPIX_VERSION:
                    return GetFlashPixVersionDescription();
                case ExifDirectory.TAG_REFERENCE_BLACK_WHITE:
                    return GetReferenceBlackWhiteDescription();
                case ExifDirectory.TAG_ISO_EQUIVALENT:
                    return GetIsoEquivalentDescription();
                case ExifDirectory.TAG_THUMBNAIL_DATA:
                    return GetThumbnailDescription();
                case ExifDirectory.TAG_XP_AUTHOR:
                    return GetXPAuthorDescription();
                case ExifDirectory.TAG_XP_COMMENTS:
                    return GetXPCommentsDescription();
                case ExifDirectory.TAG_XP_KEYWORDS:
                    return GetXPKeywordsDescription();
                case ExifDirectory.TAG_XP_SUBJECT:
                    return GetXPSubjectDescription();
                case ExifDirectory.TAG_XP_TITLE:
                    return GetXPTitleDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Thumbnail Description.
        /// </summary>
        /// <returns>the Thumbnail Description.</returns>
        private string GetThumbnailDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_THUMBNAIL_DATA))
                return null;
            int[] thumbnailBytes =
                _directory.GetIntArray(ExifDirectory.TAG_THUMBNAIL_DATA);
            return BUNDLE["THUMBNAIL_BYTES", thumbnailBytes.Length.ToString()];
        }

        /// <summary>
        /// Returns the Iso Equivalent Description.
        /// </summary>
        /// <returns>the Iso Equivalent Description.</returns>
        private string GetIsoEquivalentDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_ISO_EQUIVALENT))
                return null;
            int isoEquiv = _directory.GetInt(ExifDirectory.TAG_ISO_EQUIVALENT);
            if (isoEquiv < 50)
            {
                isoEquiv *= 200;
            }
            return isoEquiv.ToString();
        }

        /// <summary>
        /// Returns the Reference Black White Description.
        /// </summary>
        /// <returns>the Reference Black White Description.</returns>
        private string GetReferenceBlackWhiteDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_REFERENCE_BLACK_WHITE))
                return null;
            int[] ints =
                _directory.GetIntArray(ExifDirectory.TAG_REFERENCE_BLACK_WHITE);

            string[] sPos = new string[] { ints[0].ToString(), ints[1].ToString(), ints[2].ToString(), ints[3].ToString(), ints[4].ToString(), ints[5].ToString() };
            return BUNDLE["POS", sPos];
        }

        /// <summary>
        /// Returns the Exif Version Description.
        /// </summary>
        /// <returns>the Exif Version Description.</returns>
        private string GetExifVersionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_EXIF_VERSION))
                return null;
            int[] ints = _directory.GetIntArray(ExifDirectory.TAG_EXIF_VERSION);
            return ExifDescriptor.ConvertBytesToVersionString(ints);
        }

        /// <summary>
        /// Returns the Flash Pix Version Description.
        /// </summary>
        /// <returns>the Flash Pix Version Description.</returns>
        private string GetFlashPixVersionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_FLASHPIX_VERSION))
                return null;
            int[] ints = _directory.GetIntArray(ExifDirectory.TAG_FLASHPIX_VERSION);
            return ExifDescriptor.ConvertBytesToVersionString(ints);
        }

        /// <summary>
        /// Returns the Scene Type Description.
        /// </summary>
        /// <returns>the Scene Type Description.</returns>
        private string GetSceneTypeDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_SCENE_TYPE))
                return null;
            int sceneType = _directory.GetInt(ExifDirectory.TAG_SCENE_TYPE);
            if (sceneType == 1)
            {
                return BUNDLE["DIRECTLY_PHOTOGRAPHED_IMAGE"];
            }
            else
            {
                return BUNDLE["UNKNOWN", sceneType.ToString()];
            }
        }

        /// <summary>
        /// Returns the File Source Description.
        /// </summary>
        /// <returns>the File Source Description.</returns>
        private string GetFileSourceDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_FILE_SOURCE))
                return null;
            int fileSource = _directory.GetInt(ExifDirectory.TAG_FILE_SOURCE);
            if (fileSource == 3)
            {
                return BUNDLE["DIGITAL_STILL_CAMERA"];
            }
            else
            {
                return BUNDLE["UNKNOWN", fileSource.ToString()];
            }
        }

        /// <summary>
        /// Returns the Exposure Bias Description.
        /// </summary>
        /// <returns>the Exposure Bias Description.</returns>
        private string GetExposureBiasDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_EXPOSURE_BIAS))
                return null;
            Rational exposureBias =
                _directory.GetRational(ExifDirectory.TAG_EXPOSURE_BIAS);
            return exposureBias.ToSimpleString(true);
        }

        /// <summary>
        /// Returns the Max Aperture Value Description.
        /// </summary>
        /// <returns>the Max Aperture Value Description.</returns>
        private string GetMaxApertureValueDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_MAX_APERTURE))
                return null;
            double apertureApex =
                _directory.GetDouble(ExifDirectory.TAG_MAX_APERTURE);
            double rootTwo = Math.Sqrt(2);
            double fStop = Math.Pow(rootTwo, apertureApex);
            return BUNDLE["APERTURE", fStop.ToString("0.#")];
        }

        /// <summary>
        /// Returns the Aperture Value Description.
        /// </summary>
        /// <returns>the Aperture Value Description.</returns>
        private string GetApertureValueDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_APERTURE))
                return null;
            double apertureApex = _directory.GetDouble(ExifDirectory.TAG_APERTURE);
            double rootTwo = Math.Sqrt(2);
            double fStop = Math.Pow(rootTwo, apertureApex);
            return BUNDLE["APERTURE", fStop.ToString("0.#")];
        }

        /// <summary>
        /// Returns the Exposure Program Description.
        /// </summary>
        /// <returns>the Exposure Program Description.</returns>
        private string GetExposureProgramDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_EXPOSURE_PROGRAM))
                return null;
            // '1' means manual control, '2' program normal, '3' aperture priority,
            // '4' shutter priority, '5' program creative (slow program),
            // '6' program action(high-speed program), '7' portrait mode, '8' landscape mode.
            switch (_directory.GetInt(ExifDirectory.TAG_EXPOSURE_PROGRAM))
            {
                case 1:
                    return BUNDLE["MANUAL_CONTROL"];
                case 2:
                    return BUNDLE["PROGRAM_NORMAL"];
                case 3:
                    return BUNDLE["APERTURE_PRIORITY"];
                case 4:
                    return BUNDLE["SHUTTER_PRIORITY"];
                case 5:
                    return BUNDLE["PROGRAM_CREATIVE"];
                case 6:
                    return BUNDLE["PROGRAM_ACTION"];
                case 7:
                    return BUNDLE["PORTRAIT_MODE"];
                case 8:
                    return BUNDLE["LANDSCAPE_MODE"];
                default:
                    return BUNDLE["UNKNOWN_PROGRAM", _directory.GetInt(ExifDirectory.TAG_EXPOSURE_PROGRAM).ToString()];
            }
        }

        /// <summary>
        /// Returns the YCbCr Subsampling Description.
        /// </summary>
        /// <returns>the YCbCr Subsampling Description.</returns>
        private string GetYCbCrSubsamplingDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_YCBCR_SUBSAMPLING))
                return null;
            int[] positions =
                _directory.GetIntArray(ExifDirectory.TAG_YCBCR_SUBSAMPLING);
            if (positions[0] == 2 && positions[1] == 1)
            {
                return BUNDLE["YCBCR_422"];
            }
            else if (positions[0] == 2 && positions[1] == 2)
            {
                return BUNDLE["YCBCR_420"];
            }
            else
            {
                return BUNDLE["UNKNOWN"];
            }
        }

        /// <summary>
        /// Returns the Planar Configuration Description.
        /// </summary>
        /// <returns>the Planar Configuration Description.</returns>
        private string GetPlanarConfigurationDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_PLANAR_CONFIGURATION))
                return null;
            // When image format is no compression YCbCr, this aValue shows byte aligns of YCbCr
            // data. If aValue is '1', Y/Cb/Cr aValue is chunky format, contiguous for each subsampling
            // pixel. If aValue is '2', Y/Cb/Cr aValue is separated and stored to Y plane/Cb plane/Cr
            // plane format.

            switch (_directory.GetInt(ExifDirectory.TAG_PLANAR_CONFIGURATION))
            {
                case 1:
                    return BUNDLE["CHUNKY"];
                case 2:
                    return BUNDLE["SEPARATE"];
                default:
                    return BUNDLE["UNKNOWN_CONFIGURATION"];
            }
        }

        /// <summary>
        /// Returns the Samples Per Pixel Description.
        /// </summary>
        /// <returns>the Samples Per Pixel Description.</returns>
        private string GetSamplesPerPixelDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_SAMPLES_PER_PIXEL))
                return null;
            return BUNDLE["SAMPLES_PIXEL", _directory.GetString(ExifDirectory.TAG_SAMPLES_PER_PIXEL)];
        }

        /// <summary>
        /// Returns the Rows Per Strip Description.
        /// </summary>
        /// <returns>the Rows Per Strip Description.</returns>
        private string GetRowsPerStripDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_ROWS_PER_STRIP))
                return null;
            return BUNDLE["ROWS_STRIP", _directory.GetString(ExifDirectory.TAG_ROWS_PER_STRIP)];
        }

        /// <summary>
        /// Returns the Strip Byte Counts Description.
        /// </summary>
        /// <returns>the Strip Byte Counts Description.</returns>
        private string GetStripByteCountsDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_STRIP_BYTE_COUNTS))
                return null;
            return BUNDLE["BYTES", _directory.GetString(ExifDirectory.TAG_STRIP_BYTE_COUNTS)];
        }

        /// <summary>
        /// Returns the Photometric Interpretation Description.
        /// </summary>
        /// <returns>the Photometric Interpretation Description.</returns>
        private string GetPhotometricInterpretationDescription()
        {
            if (!_directory
                .ContainsTag(ExifDirectory.TAG_PHOTOMETRIC_INTERPRETATION))
                return null;
            // Shows the color space of the image data components. '1' means monochrome,
            // '2' means RGB, '6' means YCbCr.
            switch (_directory
                .GetInt(ExifDirectory.TAG_PHOTOMETRIC_INTERPRETATION))
            {
                case 1:
                    return BUNDLE["MONOCHROME"];
                case 2:
                    return BUNDLE["RGB"];
                case 6:
                    return BUNDLE["YCBCR"];
                default:
                    return BUNDLE["UNKNOWN_COLOUR_SPACE"];
            }
        }

        /// <summary>
        /// Returns the Compression Description.
        /// </summary>
        /// <returns>the Compression Description.</returns>
        private string GetCompressionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_COMPRESSION))
                return null;
            // '1' means no compression, '6' means JPEG compression.
            switch (_directory.GetInt(ExifDirectory.TAG_COMPRESSION))
            {
                case 1:
                    return BUNDLE["NO_COMPRESSION"];
                case 6:
                    return BUNDLE["JPEG_COMPRESSION"];
                default:
                    return BUNDLE["UNKNOWN_COMPRESSION"];
            }
        }

        /// <summary>
        /// Returns the Bits Per Sample Description.
        /// </summary>
        /// <returns>the Bits Per Sample Description.</returns>
        private string GetBitsPerSampleDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_BITS_PER_SAMPLE))
                return null;
            return BUNDLE["BITS_COMPONENT_PIXEL", _directory.GetString(ExifDirectory.TAG_BITS_PER_SAMPLE)];
        }

        /// <summary>
        /// Returns the Thumbnail Image Width Description.
        /// </summary>
        /// <returns>the Thumbnail Image Width Description.</returns>
        private string GetThumbnailImageWidthDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_THUMBNAIL_IMAGE_WIDTH))
                return null;
            return BUNDLE["PIXELS", _directory.GetString(ExifDirectory.TAG_THUMBNAIL_IMAGE_WIDTH)];
        }

        /// <summary>
        /// Returns the Thumbnail Image Height Description.
        /// </summary>
        /// <returns>the Thumbnail Image Height Description.</returns>
        private string GetThumbnailImageHeightDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_THUMBNAIL_IMAGE_HEIGHT))
                return null;
            return BUNDLE["PIXELS", _directory.GetString(ExifDirectory.TAG_THUMBNAIL_IMAGE_HEIGHT)];
        }

        /// <summary>
        /// Returns the Focal Plane X Resolution Description.
        /// </summary>
        /// <returns>the Focal Plane X Resolution Description.</returns>
        private string GetFocalPlaneXResolutionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_FOCAL_PLANE_X_RES))
                return null;
            Rational rational =
                _directory.GetRational(ExifDirectory.TAG_FOCAL_PLANE_X_RES);
            return BUNDLE["FOCAL_PLANE", rational.GetReciprocal().ToSimpleString(_allowDecimalRepresentationOfRationals),
            GetFocalPlaneResolutionUnitDescription().ToLower()];
        }

        /// <summary>
        /// Returns the Focal Plane Y Resolution Description.
        /// </summary>
        /// <returns>the Focal Plane Y Resolution Description.</returns>
        private string GetFocalPlaneYResolutionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_COMPRESSION))
                return null;
            Rational rational =
                _directory.GetRational(ExifDirectory.TAG_FOCAL_PLANE_Y_RES);
            return BUNDLE["FOCAL_PLANE", rational.GetReciprocal().ToSimpleString(_allowDecimalRepresentationOfRationals),
                GetFocalPlaneResolutionUnitDescription().ToLower()];
        }

        /// <summary>
        /// Returns the Focal Plane Resolution Unit Description.
        /// </summary>
        /// <returns>the Focal Plane Resolution Unit Description.</returns>
        private string GetFocalPlaneResolutionUnitDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_FOCAL_PLANE_UNIT))
                return null;
            // Unit of FocalPlaneXResoluton/FocalPlaneYResolution. '1' means no-unit,
            // '2' inch, '3' centimeter.
            switch (_directory.GetInt(ExifDirectory.TAG_FOCAL_PLANE_UNIT))
            {
                case 1:
                    return BUNDLE["NO_UNIT"];
                case 2:
                    return BUNDLE["INCHES"];
                case 3:
                    return BUNDLE["CM"];
                default:
                    return "";
            }
        }

        /// <summary>
        /// Returns the Exif Image Width Description.
        /// </summary>
        /// <returns>the Exif Image Width Description.</returns>
        private string GetExifImageWidthDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_EXIF_IMAGE_WIDTH))
                return null;
            return BUNDLE["PIXELS", _directory.GetInt(ExifDirectory.TAG_EXIF_IMAGE_WIDTH).ToString()];
        }

        /// <summary>
        /// Returns the Exif Image Height Description.
        /// </summary>
        /// <returns>the Exif Image Height Description.</returns>
        private string GetExifImageHeightDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_EXIF_IMAGE_HEIGHT))
                return null;
            return BUNDLE["PIXELS", _directory.GetInt(ExifDirectory.TAG_EXIF_IMAGE_HEIGHT).ToString()];
        }

        /// <summary>
        /// Returns the Color Space Description.
        /// </summary>
        /// <returns>the Color Space Description.</returns>
        private string GetColorSpaceDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_COLOR_SPACE))
                return null;
            int colorSpace = _directory.GetInt(ExifDirectory.TAG_COLOR_SPACE);
            if (colorSpace == 1)
            {
                return BUNDLE["SRGB"];
            }
            else if (colorSpace == 65535)
            {
                return BUNDLE["UNDEFINED"];
            }
            else
            {
                return BUNDLE["UNKNOWN"];
            }
        }

        /// <summary>
        /// Returns the Focal Length Description.
        /// </summary>
        /// <returns>the Focal Length Description.</returns>
        private string GetFocalLengthDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_FOCAL_LENGTH))
                return null;
            Rational focalLength =
                _directory.GetRational(ExifDirectory.TAG_FOCAL_LENGTH);
            return BUNDLE["DISTANCE_MM", (focalLength.DoubleValue()).ToString("0.0##")];
        }

        /// <summary>
        /// Returns the Flash Description.
        /// </summary>
        /// <returns>the Flash Description.</returns>
        private string GetFlashDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_FLASH))
                return null;
            // '0' means flash did not fire, '1' flash fired, '5' flash fired but strobe return
            // light not detected, '7' flash fired and strobe return light detected.
            switch (_directory.GetInt(ExifDirectory.TAG_FLASH))
            {
                case 0:
                    return BUNDLE["NO_FLASH_FIRED"];
                case 1:
                    return BUNDLE["FLASH_FIRED"];
                case 5:
                    return BUNDLE["FLASH_FIRED_LIGHT_NOT_DETECTED"];
                case 7:
                    return BUNDLE["FLASH_FIRED_LIGHT_DETECTED"];
                default:
                    return BUNDLE["UNKNOWN", _directory.GetInt(ExifDirectory.TAG_FLASH).ToString()];
            }
        }

        /// <summary>
        /// Returns the White Balance Description.
        /// </summary>
        /// <returns>the White Balance Description.</returns>
        private string GetWhiteBalanceDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_WHITE_BALANCE))
                return null;
            // '0' means unknown, '1' daylight, '2' fluorescent, '3' tungsten, '10' flash,
            // '17' standard light A, '18' standard light B, '19' standard light C, '20' D55,
            // '21' D65, '22' D75, '255' other.
            switch (_directory.GetInt(ExifDirectory.TAG_WHITE_BALANCE))
            {
                case 0:
                    return BUNDLE["UNKNOWN"];
                case 1:
                    return BUNDLE["DAYLIGHT"];
                case 2:
                    return BUNDLE["FLOURESCENT"];
                case 3:
                    return BUNDLE["TUNGSTEN"];
                case 10:
                    return BUNDLE["FLASH"];
                case 17:
                    return BUNDLE["STANDARD_LIGHT"];
                case 18:
                    return BUNDLE["STANDARD_LIGHT_B"];
                case 19:
                    return BUNDLE["STANDARD_LIGHT_C"];
                case 20:
                    return BUNDLE["D55"];
                case 21:
                    return BUNDLE["D65"];
                case 22:
                    return BUNDLE["D75"];
                case 255:
                    return BUNDLE["OTHER"];
                default:
                    return BUNDLE["UNKNOWN", _directory.GetInt(ExifDirectory.TAG_WHITE_BALANCE).ToString()];
            }
        }

        /// <summary>
        /// Returns the Metering Mode Description.
        /// </summary>
        /// <returns>the Metering Mode Description.</returns>
        private string GetMeteringModeDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_METERING_MODE))
                return null;
            // '0' means unknown, '1' average, '2' center weighted average, '3' spot
            // '4' multi-spot, '5' multi-segment, '6' partial, '255' other
            int meteringMode = _directory.GetInt(ExifDirectory.TAG_METERING_MODE);
            switch (meteringMode)
            {
                case 0:
                    return BUNDLE["UNKNOWN"];
                case 1:
                    return BUNDLE["AVERAGE"];
                case 2:
                    return BUNDLE["CENTER_WEIGHTED_AVERAGE"];
                case 3:
                    return BUNDLE["SPOT"];
                case 4:
                    return BUNDLE["MULTI_SPOT"];
                case 5:
                    return BUNDLE["MULTI_SEGMENT"];
                case 6:
                    return BUNDLE["PARTIAL"];
                case 255:
                    return BUNDLE["OTHER"];
                default:
                    return "";
            }
        }

        /// <summary>
        /// Returns the Subject Distance Description.
        /// </summary>
        /// <returns>the Subject Distance Description.</returns>
        private string GetSubjectDistanceDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_SUBJECT_DISTANCE))
                return null;
            Rational distance =
                _directory.GetRational(ExifDirectory.TAG_SUBJECT_DISTANCE);
            return BUNDLE["METRES", (distance.DoubleValue()).ToString("0.0##")];
        }

        /// <summary>
        /// Returns the Compression Level Description.
        /// </summary>
        /// <returns>the Compression Level Description.</returns>
        private string GetCompressionLevelDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_COMPRESSION_LEVEL))
                return null;
            Rational compressionRatio =
                _directory.GetRational(ExifDirectory.TAG_COMPRESSION_LEVEL);
            string ratio =
                compressionRatio.ToSimpleString(
                _allowDecimalRepresentationOfRationals);
            if (compressionRatio.IsInteger() && compressionRatio.IntValue() == 1)
            {
                return BUNDLE["BIT_PIXEL", ratio];
            }
            else
            {
                return BUNDLE["BITS_PIXEL", ratio];
            }
        }

        /// <summary>
        /// Returns the Thumbnail Length Description.
        /// </summary>
        /// <returns>the Thumbnail Length Description.</returns>
        private string GetThumbnailLengthDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_THUMBNAIL_LENGTH))
                return null;
            return BUNDLE["BYTES", _directory.GetString(ExifDirectory.TAG_THUMBNAIL_LENGTH)];
        }

        /// <summary>
        /// Returns the Thumbnail OffSet Description.
        /// </summary>
        /// <returns>the Thumbnail OffSet Description.</returns>
        private string GetThumbnailOffSetDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_THUMBNAIL_OFFSET))
                return null;
            return BUNDLE["BYTES", _directory.GetString(ExifDirectory.TAG_THUMBNAIL_OFFSET)];
        }

        /// <summary>
        /// Returns the Y Resolution Description.
        /// </summary>
        /// <returns>the Y Resolution Description.</returns>
        private string GetYResolutionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_Y_RESOLUTION))
                return null;
            Rational resolution =
                _directory.GetRational(ExifDirectory.TAG_Y_RESOLUTION);
            return BUNDLE["DOTS_PER", resolution.ToSimpleString(_allowDecimalRepresentationOfRationals), GetResolutionDescription().ToLower()];
        }

        /// <summary>
        /// Returns the X Resolution Description.
        /// </summary>
        /// <returns>the X Resolution Description.</returns>
        private string GetXResolutionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_X_RESOLUTION))
                return null;
            Rational resolution =
                _directory.GetRational(ExifDirectory.TAG_X_RESOLUTION);
            return BUNDLE["DOTS_PER", resolution.ToSimpleString(_allowDecimalRepresentationOfRationals), GetResolutionDescription().ToLower()];
        }

        /// <summary>
        /// Returns the Exposure Time Description.
        /// </summary>
        /// <returns>the Exposure Time Description.</returns>
        private string GetExposureTimeDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_EXPOSURE_TIME))
                return null;
            return BUNDLE["SEC", _directory.GetString(ExifDirectory.TAG_EXPOSURE_TIME)];
        }

        /// <summary>
        /// Returns the Shutter Speed Description.
        /// </summary>
        /// <returns>the Shutter Speed Description.</returns>
        private string GetShutterSpeedDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_SHUTTER_SPEED))
                return null;
            // Incorrect math bug fixed by Hendrik Wördehoff - 20 Sep 2002
            int apexValue = _directory.GetInt(ExifDirectory.TAG_SHUTTER_SPEED);
            // int apexPower = (int)(Math.pow(2.0, apexValue) + 0.5);
            // addition of 0.5 removed upon suggestion of Varuni Witana, who
            // detected incorrect values for Canon cameras,
            // which calculate both shutterspeed and exposuretime
            int apexPower = (int)Math.Pow(2.0, apexValue);
            return BUNDLE["SHUTTER_SPEED", apexPower.ToString()];
        }

        /// <summary>
        /// Returns the F Number Description.
        /// </summary>
        /// <returns>the F Number Description.</returns>
        private string GetFNumberDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_FNUMBER))
                return null;
            Rational fNumber = _directory.GetRational(ExifDirectory.TAG_FNUMBER);
            return BUNDLE["APERTURE", fNumber.DoubleValue().ToString("0.#")];
        }

        /// <summary>
        /// Returns the YCbCr Positioning Description.
        /// </summary>
        /// <returns>the YCbCr Positioning Description.</returns>
        private string GetYCbCrPositioningDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_YCBCR_POSITIONING))
                return null;
            int yCbCrPosition =
                _directory.GetInt(ExifDirectory.TAG_YCBCR_POSITIONING);
            switch (yCbCrPosition)
            {
                case 1:
                    return BUNDLE["CENTER_OF_PIXEL_ARRAY"];
                case 2:
                    return BUNDLE["DATUM_POINT"];
                default:
                    return yCbCrPosition.ToString();
            }
        }

        /// <summary>
        /// Returns the Orientation Description.
        /// </summary>
        /// <returns>the Orientation Description.</returns>
        private string GetOrientationDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_ORIENTATION))
                return null;
            int orientation = _directory.GetInt(ExifDirectory.TAG_ORIENTATION);
            switch (orientation)
            {
                case 1:
                    return BUNDLE["TOP_LEFT_SIDE"];
                case 2:
                    return BUNDLE["TOP_RIGHT_SIDE"];
                case 3:
                    return BUNDLE["BOTTOM_RIGHT_SIDE"];
                case 4:
                    return BUNDLE["BOTTOM_LEFT_SIDE"];
                case 5:
                    return BUNDLE["LEFT_SIDE_TOP"];
                case 6:
                    return BUNDLE["RIGHT_SIDE_TOP"];
                case 7:
                    return BUNDLE["RIGHT_SIDE_BOTTOM"];
                case 8:
                    return BUNDLE["LEFT_SIDE_BOTTOM"];
                default:
                    return orientation.ToString();
            }
        }

        /// <summary>
        /// Returns the Resolution Description.
        /// </summary>
        /// <returns>the Resolution Description.</returns>
        private string GetResolutionDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_RESOLUTION_UNIT))
                return "";
            // '1' means no-unit, '2' means inch, '3' means centimeter. Default aValue is '2'(inch)
            int resolutionUnit =
                _directory.GetInt(ExifDirectory.TAG_RESOLUTION_UNIT);
            switch (resolutionUnit)
            {
                case 1:
                    return BUNDLE["NO_UNIT"];
                case 2:
                    return BUNDLE["INCHES"];
                case 3:
                    return BUNDLE["CM"];
                default:
                    return "";
            }
        }

        /// <summary>
        /// Returns the Sensing Method Description.
        /// </summary>
        /// <returns>the Sensing Method Description.</returns>
        private string GetSensingMethodDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_SENSING_METHOD))
                return null;
            // '1' Not defined, '2' One-chip color area sensor, '3' Two-chip color area sensor
            // '4' Three-chip color area sensor, '5' Color sequential area sensor
            // '7' Trilinear sensor '8' Color sequential linear sensor,  'Other' reserved
            int sensingMethod = _directory.GetInt(ExifDirectory.TAG_SENSING_METHOD);
            switch (sensingMethod)
            {
                case 1:
                    return BUNDLE["NOT_DEFINED"];
                case 2:
                    return BUNDLE["ONE_CHIP_COLOR"];
                case 3:
                    return BUNDLE["TWO_CHIP_COLOR"];
                case 4:
                    return BUNDLE["THREE_CHIP_COLOR"];
                case 5:
                    return BUNDLE["COLOR_SEQUENTIAL"];
                case 7:
                    return BUNDLE["TRILINEAR_SENSOR"];
                case 8:
                    return BUNDLE["COLOR_SEQUENTIAL_LINEAR"];
                default:
                    return "";
            }
        }

        /// <summary>
        /// Returns the XP author description.
        /// </summary>
        /// <returns>the XP author description.</returns>
        private string GetXPAuthorDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_XP_AUTHOR))
                return null;
            return Utils.Decode(_directory.GetByteArray(ExifDirectory.TAG_XP_AUTHOR), true);
        }

        /// <summary>
        /// Returns the XP comments description.
        /// </summary>
        /// <returns>the XP comments description.</returns>
        private string GetXPCommentsDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_XP_COMMENTS))
                return null;
            return Utils.Decode(_directory.GetByteArray(ExifDirectory.TAG_XP_COMMENTS), true);
        }

        /// <summary>
        /// Returns the XP keywords description.
        /// </summary>
        /// <returns>the XP keywords description.</returns>
        private string GetXPKeywordsDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_XP_KEYWORDS))
                return null;
            return Utils.Decode(_directory.GetByteArray(ExifDirectory.TAG_XP_KEYWORDS), true);
        }

        /// <summary>
        /// Returns the XP subject description.
        /// </summary>
        /// <returns>the XP subject description.</returns>
        private string GetXPSubjectDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_XP_SUBJECT))
                return null;
            return Utils.Decode(_directory.GetByteArray(ExifDirectory.TAG_XP_SUBJECT), true);
        }

        /// <summary>
        /// Returns the XP title description.
        /// </summary>
        /// <returns>the XP title description.</returns>
        private string GetXPTitleDescription()
        {
            if (!_directory.ContainsTag(ExifDirectory.TAG_XP_TITLE))
                return null;
            return Utils.Decode(_directory.GetByteArray(ExifDirectory.TAG_XP_TITLE), true);
        }


        /// <summary>
        /// Returns the Component Configuration Description.
        /// </summary>
        /// <returns>the Component Configuration Description.</returns>
        private string GetComponentConfigurationDescription()
        {
            int[] components =
                _directory.GetIntArray(ExifDirectory.TAG_COMPONENTS_CONFIGURATION);
            string[] componentStrings = { "", "Y", "Cb", "Cr", "R", "G", "B" };
            StringBuilder componentConfig = new StringBuilder();
            for (int i = 0; i < Math.Min(4, components.Length); i++)
            {
                int j = components[i];
                if (j > 0 && j < componentStrings.Length)
                {
                    componentConfig.Append(componentStrings[j]);
                }
            }
            return componentConfig.ToString();
        }

        /// <summary>
        /// Takes a series of 4 bytes from the specified offSet, and converts these to a
        /// well-known version number, where possible.  For example, (hex) 30 32 31 30 == 2.10).
        /// </summary>
        /// <param name="components">the four version values</param>
        /// <returns>the version as a string of form 2.10</returns>
        public static string ConvertBytesToVersionString(int[] components)
        {
            StringBuilder version = new StringBuilder();
            for (int i = 0; i < 4 && i < components.Length; i++)
            {
                if (i == 2)
                    version.Append('.');
                string digit = ((char)components[i]).ToString();
                if (i == 0 && "0".Equals(digit))
                    continue;
                version.Append(digit);
            }
            return version.ToString();
        }
    }

    /// <summary>
    /// The GPS Directory class
    /// </summary>
    public class GpsDirectory : Directory
    {
        /// <summary>
        /// GPS tag version GPSVersionID 0 0 BYTE 4
        /// </summary>
        public const int TAG_GPS_VERSION_ID = 0x0000;
        /// <summary>
        /// North or South Latitude GPSLatitudeRef 1 1 ASCII 2
        /// </summary>
        public const int TAG_GPS_LATITUDE_REF = 0x0001;
        /// <summary>
        /// Latitude GPSLatitude 2 2 RATIONAL 3
        /// </summary>
        public const int TAG_GPS_LATITUDE = 0x0002;
        /// <summary>
        /// East or West Longitude GPSLongitudeRef 3 3 ASCII 2
        /// </summary>
        public const int TAG_GPS_LONGITUDE_REF = 0x0003;
        /// <summary>
        /// Longitude GPSLongitude 4 4 RATIONAL 3
        /// </summary>
        public const int TAG_GPS_LONGITUDE = 0x0004;
        /// <summary>
        /// Altitude reference GPSAltitudeRef 5 5 BYTE 1
        /// </summary>
        public const int TAG_GPS_ALTITUDE_REF = 0x0005;
        /// <summary>
        /// Altitude GPSAltitude 6 6 RATIONAL 1
        /// </summary>
        public const int TAG_GPS_ALTITUDE = 0x0006;
        /// <summary>
        /// GPS time (atomic clock) GPSTimeStamp 7 7 RATIONAL 3
        /// </summary>
        public const int TAG_GPS_TIME_STAMP = 0x0007;
        /// <summary>
        /// GPS satellites used for measurement GPSSatellites 8 8 ASCII Any
        /// </summary>
        public const int TAG_GPS_SATELLITES = 0x0008;
        /// <summary>
        /// GPS receiver status GPSStatus 9 9 ASCII 2
        /// </summary>
        public const int TAG_GPS_STATUS = 0x0009;
        /// <summary>
        /// GPS measurement mode GPSMeasureMode 10 A ASCII 2
        /// </summary>
        public const int TAG_GPS_MEASURE_MODE = 0x000A;
        /// <summary>
        /// Measurement precision GPSDOP 11 B RATIONAL 1
        /// </summary>
        public const int TAG_GPS_DOP = 0x000B;
        /// <summary>
        /// Speed unit GPSSpeedRef 12 C ASCII 2
        /// </summary>
        public const int TAG_GPS_SPEED_REF = 0x000C;
        /// <summary>
        /// Speed of GPS receiver GPSSpeed 13 D RATIONAL 1
        /// </summary>
        public const int TAG_GPS_SPEED = 0x000D;
        /// <summary>
        /// Reference for direction of movement GPSTrackRef 14 E ASCII 2
        /// </summary>
        public const int TAG_GPS_TRACK_REF = 0x000E;
        /// <summary>
        /// Direction of movement GPSTrack 15 F RATIONAL 1
        /// </summary>
        public const int TAG_GPS_TRACK = 0x000F;
        /// <summary>
        /// Reference for direction of image GPSImgDirectionRef 16 10 ASCII 2
        /// </summary>
        public const int TAG_GPS_IMG_DIRECTION_REF = 0x0010;
        /// <summary>
        /// Direction of image GPSImgDirection 17 11 RATIONAL 1
        /// </summary>
        public const int TAG_GPS_IMG_DIRECTION = 0x0011;
        /// <summary>
        /// Geodetic survey data used GPSMapDatum 18 12 ASCII Any
        /// </summary>
        public const int TAG_GPS_MAP_DATUM = 0x0012;
        /// <summary>
        /// Reference for latitude of destination GPSDestLatitudeRef 19 13 ASCII 2
        /// </summary>
        public const int TAG_GPS_DEST_LATITUDE_REF = 0x0013;
        /// <summary>
        /// Latitude of destination GPSDestLatitude 20 14 RATIONAL 3
        /// </summary>
        public const int TAG_GPS_DEST_LATITUDE = 0x0014;
        /// <summary>
        /// Reference for longitude of destination GPSDestLongitudeRef 21 15 ASCII 2
        /// </summary>
        public const int TAG_GPS_DEST_LONGITUDE_REF = 0x0015;
        /// <summary>
        /// Longitude of destination GPSDestLongitude 22 16 RATIONAL 3
        /// </summary>
        public const int TAG_GPS_DEST_LONGITUDE = 0x0016;
        /// <summary>
        /// Reference for bearing of destination GPSDestBearingRef 23 17 ASCII 2
        /// </summary>
        public const int TAG_GPS_DEST_BEARING_REF = 0x0017;
        /// <summary>
        /// Bearing of destination GPSDestBearing 24 18 RATIONAL 1
        /// </summary>
        public const int TAG_GPS_DEST_BEARING = 0x0018;
        /// <summary>
        /// Reference for distance to destination GPSDestDistanceRef 25 19 ASCII 2
        /// </summary>
        public const int TAG_GPS_DEST_DISTANCE_REF = 0x0019;
        /// <summary>
        /// Distance to destination GPSDestDistance 26 1A RATIONAL 1
        /// </summary>
        public const int TAG_GPS_DEST_DISTANCE = 0x001A;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("GpsMarkernote");
        protected static readonly IDictionary tagNameMap = GpsDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_GPS_VERSION_ID, BUNDLE["TAG_GPS_VERSION_ID"]);
            resu.Add(TAG_GPS_LATITUDE_REF, BUNDLE["TAG_GPS_LATITUDE_REF"]);
            resu.Add(TAG_GPS_LATITUDE, BUNDLE["TAG_GPS_LATITUDE"]);
            resu.Add(TAG_GPS_LONGITUDE_REF, BUNDLE["TAG_GPS_LONGITUDE_REF"]);
            resu.Add(TAG_GPS_LONGITUDE, BUNDLE["TAG_GPS_LONGITUDE"]);
            resu.Add(TAG_GPS_ALTITUDE_REF, BUNDLE["TAG_GPS_ALTITUDE_REF"]);
            resu.Add(TAG_GPS_ALTITUDE, BUNDLE["TAG_GPS_ALTITUDE"]);
            resu.Add(TAG_GPS_TIME_STAMP, BUNDLE["TAG_GPS_TIME_STAMP"]);
            resu.Add(TAG_GPS_SATELLITES, BUNDLE["TAG_GPS_SATELLITES"]);
            resu.Add(TAG_GPS_STATUS, BUNDLE["TAG_GPS_STATUS"]);
            resu.Add(TAG_GPS_MEASURE_MODE, BUNDLE["TAG_GPS_MEASURE_MODE"]);
            resu.Add(TAG_GPS_DOP, BUNDLE["TAG_GPS_DOP"]);
            resu.Add(TAG_GPS_SPEED_REF, BUNDLE["TAG_GPS_SPEED_REF"]);
            resu.Add(TAG_GPS_SPEED, BUNDLE["TAG_GPS_SPEED"]);
            resu.Add(TAG_GPS_TRACK_REF, BUNDLE["TAG_GPS_TRACK_REF"]);
            resu.Add(TAG_GPS_TRACK, BUNDLE["TAG_GPS_TRACK"]);
            resu.Add(TAG_GPS_IMG_DIRECTION_REF, BUNDLE["TAG_GPS_IMG_DIRECTION_REF"]);
            resu.Add(TAG_GPS_IMG_DIRECTION, BUNDLE["TAG_GPS_IMG_DIRECTION"]);
            resu.Add(TAG_GPS_MAP_DATUM, BUNDLE["TAG_GPS_MAP_DATUM"]);
            resu.Add(TAG_GPS_DEST_LATITUDE_REF, BUNDLE["TAG_GPS_DEST_LATITUDE_REF"]);
            resu.Add(TAG_GPS_DEST_LATITUDE, BUNDLE["TAG_GPS_DEST_LATITUDE"]);
            resu.Add(TAG_GPS_DEST_LONGITUDE_REF, BUNDLE["TAG_GPS_DEST_LONGITUDE_REF"]);
            resu.Add(TAG_GPS_DEST_LONGITUDE, BUNDLE["TAG_GPS_DEST_LONGITUDE"]);
            resu.Add(TAG_GPS_DEST_BEARING_REF, BUNDLE["TAG_GPS_DEST_BEARING_REF"]);
            resu.Add(TAG_GPS_DEST_BEARING, BUNDLE["TAG_GPS_DEST_BEARING"]);
            resu.Add(TAG_GPS_DEST_DISTANCE_REF, BUNDLE["TAG_GPS_DEST_DISTANCE_REF"]);
            resu.Add(TAG_GPS_DEST_DISTANCE, BUNDLE["TAG_GPS_DEST_DISTANCE"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public GpsDirectory()
            : base()
        {
            this.SetDescriptor(new GpsDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// Tag descriptor for GPS
    /// </summary>
    public class GpsDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public GpsDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case GpsDirectory.TAG_GPS_ALTITUDE:
                    return GetGpsAltitudeDescription();
                case GpsDirectory.TAG_GPS_ALTITUDE_REF:
                    return GetGpsAltitudeRefDescription();
                case GpsDirectory.TAG_GPS_STATUS:
                    return GetGpsStatusDescription();
                case GpsDirectory.TAG_GPS_MEASURE_MODE:
                    return GetGpsMeasureModeDescription();
                case GpsDirectory.TAG_GPS_SPEED_REF:
                    return GetGpsSpeedRefDescription();
                case GpsDirectory.TAG_GPS_TRACK_REF:
                case GpsDirectory.TAG_GPS_IMG_DIRECTION_REF:
                case GpsDirectory.TAG_GPS_DEST_BEARING_REF:
                    return GetGpsDirectionReferenceDescription(tagType);
                case GpsDirectory.TAG_GPS_TRACK:
                case GpsDirectory.TAG_GPS_IMG_DIRECTION:
                case GpsDirectory.TAG_GPS_DEST_BEARING:
                    return GetGpsDirectionDescription(tagType);
                case GpsDirectory.TAG_GPS_DEST_DISTANCE_REF:
                    return GetGpsDestinationReferenceDescription();
                case GpsDirectory.TAG_GPS_TIME_STAMP:
                    return GetGpsTimeStampDescription();
                // three rational numbers -- displayed in HH"MM"SS.ss
                case GpsDirectory.TAG_GPS_LONGITUDE:
                    return GetGpsLongitudeDescription();
                case GpsDirectory.TAG_GPS_LATITUDE:
                    return GetGpsLatitudeDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Gps Latitude Description.
        /// </summary>
        /// <returns>the Gps Latitude Description.</returns>
        private string GetGpsLatitudeDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_LATITUDE))
                return null;
            return GetHoursMinutesSecondsDescription(GpsDirectory.TAG_GPS_LATITUDE);
        }

        /// <summary>
        /// Returns the Gps Longitude Description.
        /// </summary>
        /// <returns>the Gps Longitude Description.</returns>
        private string GetGpsLongitudeDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_LONGITUDE))
                return null;
            return GetHoursMinutesSecondsDescription(
                GpsDirectory.TAG_GPS_LONGITUDE);
        }

        /// <summary>
        /// Returns the Hours Minutes Seconds Description.
        /// </summary>
        /// <returns>the Hours Minutes Seconds Description.</returns>
        private string GetHoursMinutesSecondsDescription(int tagType)
        {
            Rational[] components = _directory.GetRationalArray(tagType);
            // TODO create an HoursMinutesSecods class ??
            int deg = components[0].IntValue();
            float min = components[1].FloatValue();
            float sec = components[2].FloatValue();
            // carry fractions of minutes into seconds -- thanks Colin Briton
            sec += (min % 1) * 60;
            string[] tab = new string[] { deg.ToString(), ((int)min).ToString(), sec.ToString() };
            return BUNDLE["HOURS_MINUTES_SECONDS", tab];
        }

        /// <summary>
        /// Returns the Gps Time Stamp Description.
        /// </summary>
        /// <returns>the Gps Time Stamp Description.</returns>
        private string GetGpsTimeStampDescription()
        {
            // time in hour, min, sec
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_TIME_STAMP))
                return null;
            int[] timeComponents =
                _directory.GetIntArray(GpsDirectory.TAG_GPS_TIME_STAMP);
            string[] tab = new string[] { timeComponents[0].ToString(), timeComponents[1].ToString(), timeComponents[2].ToString() };
            return BUNDLE["GPS_TIME_STAMP", tab];
        }

        /// <summary>
        /// Returns the Gps Destination Reference Description.
        /// </summary>
        /// <returns>the Gps Destination Reference Description.</returns>
        private string GetGpsDestinationReferenceDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_DEST_DISTANCE_REF))
                return null;
            string destRef =
                _directory.GetString(GpsDirectory.TAG_GPS_DEST_DISTANCE_REF).Trim().ToUpper();
            if ("K".Equals(destRef))
            {
                return BUNDLE["KILOMETERS"];
            }
            else if ("M".Equals(destRef))
            {
                return BUNDLE["MILES"];
            }
            else if ("N".Equals(destRef))
            {
                return BUNDLE["KNOTS"];
            }
            else
            {
                return BUNDLE["UNKNOWN", destRef];
            }
        }

        /// <summary>
        /// Returns the Gps Direction Description.
        /// </summary>
        /// <returns>the Gps Direction Description.</returns>
        private string GetGpsDirectionDescription(int tagType)
        {
            if (!_directory.ContainsTag(tagType))
                return null;
            string gpsDirection = _directory.GetString(tagType).Trim();
            return BUNDLE["DEGREES", gpsDirection];
        }

        /// <summary>
        /// Returns the Gps Direction Reference Description.
        /// </summary>
        /// <returns>the Gps Direction Reference Description.</returns>
        private string GetGpsDirectionReferenceDescription(int tagType)
        {
            if (!_directory.ContainsTag(tagType))
                return null;
            string gpsDistRef = _directory.GetString(tagType).Trim().ToUpper();
            if ("T".Equals(gpsDistRef))
            {
                return BUNDLE["TRUE_DIRECTION"];
            }
            else if ("M".Equals(gpsDistRef))
            {
                return BUNDLE["MAGNETIC_DIRECTION"];
            }
            else
            {
                return BUNDLE["UNKNOWN", gpsDistRef];
            }
        }

        /// <summary>
        /// Returns the Gps Speed Ref Description.
        /// </summary>
        /// <returns>the Gps Speed Ref Description.</returns>
        private string GetGpsSpeedRefDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_SPEED_REF))
                return null;
            string gpsSpeedRef =
                _directory.GetString(GpsDirectory.TAG_GPS_SPEED_REF).Trim().ToUpper();
            if ("K".Equals(gpsSpeedRef))
            {
                return BUNDLE["KPH"];
            }
            else if ("M".Equals(gpsSpeedRef))
            {
                return BUNDLE["MPH"];
            }
            else if ("N".Equals(gpsSpeedRef))
            {
                return BUNDLE["KNOTS"];
            }
            else
            {
                return BUNDLE["UNKNOWN", gpsSpeedRef];
            }
        }

        /// <summary>
        /// Returns the Gps Measure Mode Description.
        /// </summary>
        /// <returns>the Gps Measure Mode Description.</returns>
        private string GetGpsMeasureModeDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_MEASURE_MODE))
                return null;
            string gpsSpeedMeasureMode =
                _directory.GetString(GpsDirectory.TAG_GPS_MEASURE_MODE).Trim().ToUpper();
            if ("2".Equals(gpsSpeedMeasureMode) || "3".Equals(gpsSpeedMeasureMode))
            {
                return BUNDLE["DIMENSIONAL_MEASUREMENT", gpsSpeedMeasureMode];
            }
            else
            {
                return BUNDLE["UNKNOWN", gpsSpeedMeasureMode];
            }
        }

        /// <summary>
        /// Returns the Gps Status Description.
        /// </summary>
        /// <returns>the Gps Status Description.</returns>
        private string GetGpsStatusDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_STATUS))
                return null;
            string gpsStatus =
                _directory.GetString(GpsDirectory.TAG_GPS_STATUS).Trim().ToUpper();
            if ("A".Equals(gpsStatus))
            {
                return BUNDLE["MEASUREMENT_IN_PROGESS"];
            }
            else if ("V".Equals(gpsStatus))
            {
                return BUNDLE["MEASUREMENT_INTEROPERABILITY"];
            }
            else
            {
                return BUNDLE["UNKNOWN", gpsStatus];
            }
        }

        /// <summary>
        /// Returns the Gps Altitude Ref Description.
        /// </summary>
        /// <returns>the Gps Altitude Ref Description.</returns>
        private string GetGpsAltitudeRefDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_ALTITUDE_REF))
                return null;
            int alititudeRef = _directory.GetInt(GpsDirectory.TAG_GPS_ALTITUDE_REF);
            if (alititudeRef == 0)
            {
                return BUNDLE["SEA_LEVEL"];
            }
            else
            {
                return BUNDLE["UNKNOWN", alititudeRef.ToString()];
            }
        }

        /// <summary>
        /// Returns the Gps Altitude Description.
        /// </summary>
        /// <returns>the Gps Altitude Description.</returns>
        private string GetGpsAltitudeDescription()
        {
            if (!_directory.ContainsTag(GpsDirectory.TAG_GPS_ALTITUDE))
                return null;
            string alititude =
                _directory.GetRational(
                GpsDirectory.TAG_GPS_ALTITUDE).ToSimpleString(
                true);
            return BUNDLE["METRES", alititude];
        }
    }

    /// <summary>
    /// This class represents CANON marker note.
    /// </summary>
    public class CanonMakernoteDirectory : Directory
    {
        // CANON cameras have some funny bespoke fields that need further processing...
        public const int TAG_CANON_CAMERA_STATE_1 = 0x0001;
        public const int TAG_CANON_CAMERA_STATE_2 = 0x0004;

        public const int TAG_CANON_IMAGE_TYPE = 0x0006;
        public const int TAG_CANON_FIRMWARE_VERSION = 0x0007;
        public const int TAG_CANON_IMAGE_NUMBER = 0x0008;
        public const int TAG_CANON_OWNER_NAME = 0x0009;
        public const int TAG_CANON_SERIAL_NUMBER = 0x000C;
        public const int TAG_CANON_UNKNOWN_1 = 0x000D;
        public const int TAG_CANON_CUSTOM_FUNCTIONS = 0x000F;

        // These 'sub'-tag values have been created for consistency -- they don't exist within the exif segment
        public const int TAG_CANON_STATE1_MACRO_MODE = 0xC101;
        public const int TAG_CANON_STATE1_SELF_TIMER_DELAY = 0xC102;
        public const int TAG_CANON_STATE1_UNKNOWN_1 = 0xC103;
        public const int TAG_CANON_STATE1_FLASH_MODE = 0xC104;
        public const int TAG_CANON_STATE1_CONTINUOUS_DRIVE_MODE = 0xC105;
        public const int TAG_CANON_STATE1_UNKNOWN_2 = 0xC106;
        public const int TAG_CANON_STATE1_FOCUS_MODE_1 = 0xC107;
        public const int TAG_CANON_STATE1_UNKNOWN_3 = 0xC108;
        public const int TAG_CANON_STATE1_UNKNOWN_4 = 0xC109;
        public const int TAG_CANON_STATE1_IMAGE_SIZE = 0xC10A;
        public const int TAG_CANON_STATE1_EASY_SHOOTING_MODE = 0xC10B;
        public const int TAG_CANON_STATE1_UNKNOWN_5 = 0xC10C;
        public const int TAG_CANON_STATE1_CONTRAST = 0xC10D;
        public const int TAG_CANON_STATE1_SATURATION = 0xC10E;
        public const int TAG_CANON_STATE1_SHARPNESS = 0xC10F;
        public const int TAG_CANON_STATE1_ISO = 0xC110;
        public const int TAG_CANON_STATE1_METERING_MODE = 0xC111;
        public const int TAG_CANON_STATE1_UNKNOWN_6 = 0xC112;
        public const int TAG_CANON_STATE1_AF_POINT_SELECTED = 0xC113;
        public const int TAG_CANON_STATE1_EXPOSURE_MODE = 0xC114;
        public const int TAG_CANON_STATE1_UNKNOWN_7 = 0xC115;
        public const int TAG_CANON_STATE1_UNKNOWN_8 = 0xC116;
        public const int TAG_CANON_STATE1_LONG_FOCAL_LENGTH = 0xC117;
        public const int TAG_CANON_STATE1_SHORT_FOCAL_LENGTH = 0xC118;
        public const int TAG_CANON_STATE1_FOCAL_UNITS_PER_MM = 0xC119;
        public const int TAG_CANON_STATE1_UNKNOWN_9 = 0xC11A;
        public const int TAG_CANON_STATE1_UNKNOWN_10 = 0xC11B;
        public const int TAG_CANON_STATE1_UNKNOWN_11 = 0xC11C;
        public const int TAG_CANON_STATE1_FLASH_DETAILS = 0xC11D;
        public const int TAG_CANON_STATE1_UNKNOWN_12 = 0xC11E;
        public const int TAG_CANON_STATE1_UNKNOWN_13 = 0xC11F;
        public const int TAG_CANON_STATE1_FOCUS_MODE_2 = 0xC120;

        public const int TAG_CANON_STATE2_WHITE_BALANCE = 0xC207;
        public const int TAG_CANON_STATE2_SEQUENCE_NUMBER = 0xC209;
        public const int TAG_CANON_STATE2_AF_POINT_USED = 0xC20E;
        public const int TAG_CANON_STATE2_FLASH_BIAS = 0xC20F;
        public const int TAG_CANON_STATE2_SUBJECT_DISTANCE = 0xC213;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("CanonMarkernote");

        // 9  A  B  C  D  E  F  10 11 12 13
        // 9  10 11 12 13 14 15 16 17 18 19
        protected static readonly IDictionary tagNameMap = CanonMakernoteDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();

            resu.Add(TAG_CANON_FIRMWARE_VERSION, BUNDLE["TAG_CANON_FIRMWARE_VERSION"]);
            resu.Add(TAG_CANON_IMAGE_NUMBER, BUNDLE["TAG_CANON_IMAGE_NUMBER"]);
            resu.Add(TAG_CANON_IMAGE_TYPE, BUNDLE["TAG_CANON_IMAGE_TYPE"]);
            resu.Add(TAG_CANON_OWNER_NAME, BUNDLE["TAG_CANON_OWNER_NAME"]);
            resu.Add(TAG_CANON_UNKNOWN_1, BUNDLE["TAG_CANON_UNKNOWN_1"]);
            resu.Add(TAG_CANON_CUSTOM_FUNCTIONS, BUNDLE["TAG_CANON_CUSTOM_FUNCTIONS"]);
            resu.Add(TAG_CANON_SERIAL_NUMBER, BUNDLE["TAG_CANON_SERIAL_NUMBER"]);
            resu.Add(TAG_CANON_STATE1_AF_POINT_SELECTED, BUNDLE["TAG_CANON_STATE1_AF_POINT_SELECTED"]);
            resu.Add(TAG_CANON_STATE1_CONTINUOUS_DRIVE_MODE, BUNDLE["TAG_CANON_STATE1_CONTINUOUS_DRIVE_MODE"]);
            resu.Add(TAG_CANON_STATE1_CONTRAST, BUNDLE["TAG_CANON_STATE1_CONTRAST"]);
            resu.Add(TAG_CANON_STATE1_EASY_SHOOTING_MODE, BUNDLE["TAG_CANON_STATE1_EASY_SHOOTING_MODE"]);
            resu.Add(TAG_CANON_STATE1_EXPOSURE_MODE, BUNDLE["TAG_CANON_STATE1_EXPOSURE_MODE"]);
            resu.Add(TAG_CANON_STATE1_FLASH_DETAILS, BUNDLE["TAG_CANON_STATE1_FLASH_DETAILS"]);
            resu.Add(TAG_CANON_STATE1_FLASH_MODE, BUNDLE["TAG_CANON_STATE1_FLASH_MODE"]);
            resu.Add(TAG_CANON_STATE1_FOCAL_UNITS_PER_MM, BUNDLE["TAG_CANON_STATE1_FOCAL_UNITS_PER_MM"]);
            resu.Add(TAG_CANON_STATE1_FOCUS_MODE_1, BUNDLE["TAG_CANON_STATE1_FOCUS_MODE_1"]);
            resu.Add(TAG_CANON_STATE1_FOCUS_MODE_2, BUNDLE["TAG_CANON_STATE1_FOCUS_MODE_2"]);
            resu.Add(TAG_CANON_STATE1_IMAGE_SIZE, BUNDLE["TAG_CANON_STATE1_IMAGE_SIZE"]);
            resu.Add(TAG_CANON_STATE1_ISO, BUNDLE["TAG_CANON_STATE1_ISO"]);
            resu.Add(TAG_CANON_STATE1_LONG_FOCAL_LENGTH, BUNDLE["TAG_CANON_STATE1_LONG_FOCAL_LENGTH"]);
            resu.Add(TAG_CANON_STATE1_MACRO_MODE, BUNDLE["TAG_CANON_STATE1_MACRO_MODE"]);
            resu.Add(TAG_CANON_STATE1_METERING_MODE, BUNDLE["TAG_CANON_STATE1_METERING_MODE"]);
            resu.Add(TAG_CANON_STATE1_SATURATION, BUNDLE["TAG_CANON_STATE1_SATURATION"]);
            resu.Add(TAG_CANON_STATE1_SELF_TIMER_DELAY, BUNDLE["TAG_CANON_STATE1_SELF_TIMER_DELAY"]);
            resu.Add(TAG_CANON_STATE1_SHARPNESS, BUNDLE["TAG_CANON_STATE1_SHARPNESS"]);
            resu.Add(TAG_CANON_STATE1_SHORT_FOCAL_LENGTH, BUNDLE["TAG_CANON_STATE1_SHORT_FOCAL_LENGTH"]);

            resu.Add(TAG_CANON_STATE1_UNKNOWN_1, BUNDLE["TAG_CANON_STATE1_UNKNOWN_1"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_2, BUNDLE["TAG_CANON_STATE1_UNKNOWN_2"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_3, BUNDLE["TAG_CANON_STATE1_UNKNOWN_3"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_4, BUNDLE["TAG_CANON_STATE1_UNKNOWN_4"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_5, BUNDLE["TAG_CANON_STATE1_UNKNOWN_5"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_6, BUNDLE["TAG_CANON_STATE1_UNKNOWN_6"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_7, BUNDLE["TAG_CANON_STATE1_UNKNOWN_7"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_8, BUNDLE["TAG_CANON_STATE1_UNKNOWN_8"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_9, BUNDLE["TAG_CANON_STATE1_UNKNOWN_9"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_10, BUNDLE["TAG_CANON_STATE1_UNKNOWN_10"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_11, BUNDLE["TAG_CANON_STATE1_UNKNOWN_11"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_12, BUNDLE["TAG_CANON_STATE1_UNKNOWN_12"]);
            resu.Add(TAG_CANON_STATE1_UNKNOWN_13, BUNDLE["TAG_CANON_STATE1_UNKNOWN_13"]);

            resu.Add(TAG_CANON_STATE2_WHITE_BALANCE, BUNDLE["TAG_CANON_STATE2_WHITE_BALANCE"]);
            resu.Add(TAG_CANON_STATE2_SEQUENCE_NUMBER, BUNDLE["TAG_CANON_STATE2_SEQUENCE_NUMBER"]);
            resu.Add(TAG_CANON_STATE2_AF_POINT_USED, BUNDLE["TAG_CANON_STATE2_AF_POINT_USED"]);
            resu.Add(TAG_CANON_STATE2_FLASH_BIAS, BUNDLE["TAG_CANON_STATE2_FLASH_BIAS"]);
            resu.Add(TAG_CANON_STATE2_SUBJECT_DISTANCE, BUNDLE["TAG_CANON_STATE2_SUBJECT_DISTANCE"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public CanonMakernoteDirectory()
            : base()
        {
            this.SetDescriptor(new CanonMakernoteDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }

        /// <summary>
        /// We need special handling for selected tags.
        /// </summary>
        /// <param name="tagType">the tag type</param>
        /// <param name="ints">what to set</param>
        public override void SetIntArray(int tagType, int[] ints)
        {
            if (tagType == TAG_CANON_CAMERA_STATE_1)
            {
                // this single tag has multiple values within
                int subTagTypeBase = 0xC100;
                // we intentionally skip the first array member
                for (int i = 1; i < ints.Length; i++)
                {
                    SetObject(subTagTypeBase + i, ints[i]);
                }
            }
            else if (tagType == TAG_CANON_CAMERA_STATE_2)
            {
                // this single tag has multiple values within
                int subTagTypeBase = 0xC200;
                // we intentionally skip the first array member
                for (int i = 1; i < ints.Length; i++)
                {
                    SetObject(subTagTypeBase + i, ints[i]);
                }
            }
            else
            {
                // no special handling...
                base.SetIntArray(tagType, ints);
            }
        }
    }

    /// <summary>
    /// Tag descriptor for a Canon camera
    /// </summary>
    public class CanonMakernoteDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public CanonMakernoteDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case CanonMakernoteDirectory.TAG_CANON_STATE1_MACRO_MODE:
                    return GetMacroModeDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_SELF_TIMER_DELAY:
                    return GetSelfTimerDelayDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_FLASH_MODE:
                    return GetFlashModeDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_CONTINUOUS_DRIVE_MODE:
                    return GetContinuousDriveModeDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_FOCUS_MODE_1:
                    return GetFocusMode1Description();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_IMAGE_SIZE:
                    return GetImageSizeDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_EASY_SHOOTING_MODE:
                    return GetEasyShootingModeDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_CONTRAST:
                    return GetContrastDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_SATURATION:
                    return GetSaturationDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_SHARPNESS:
                    return GetSharpnessDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_ISO:
                    return GetIsoDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_METERING_MODE:
                    return GetMeteringModeDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_AF_POINT_SELECTED:
                    return GetAfPointSelectedDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_EXPOSURE_MODE:
                    return GetExposureModeDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_LONG_FOCAL_LENGTH:
                    return GetLongFocalLengthDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_SHORT_FOCAL_LENGTH:
                    return GetShortFocalLengthDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_FOCAL_UNITS_PER_MM:
                    return GetFocalUnitsPerMillimetreDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_FLASH_DETAILS:
                    return GetFlashDetailsDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE1_FOCUS_MODE_2:
                    return GetFocusMode2Description();
                case CanonMakernoteDirectory.TAG_CANON_STATE2_WHITE_BALANCE:
                    return GetWhiteBalanceDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE2_AF_POINT_USED:
                    return GetAfPointUsedDescription();
                case CanonMakernoteDirectory.TAG_CANON_STATE2_FLASH_BIAS:
                    return GetFlashBiasDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Flash Bias  Description.
        /// </summary>
        /// <returns>the Flash Bias  Description.</returns>
        private string GetFlashBiasDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE2_FLASH_BIAS))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE2_FLASH_BIAS);
            switch (aValue)
            {
                case 0xffc0:
                    return BUNDLE["FLASH_BIAS_N_2"];
                case 0xffcc:
                    return BUNDLE["FLASH_BIAS_N_167"];
                case 0xffd0:
                    return BUNDLE["FLASH_BIAS_N_150"];
                case 0xffd4:
                    return BUNDLE["FLASH_BIAS_N_133"];
                case 0xffe0:
                    return BUNDLE["FLASH_BIAS_N_1"];
                case 0xffec:
                    return BUNDLE["FLASH_BIAS_N_067"];
                case 0xfff0:
                    return BUNDLE["FLASH_BIAS_N_050"];
                case 0xfff4:
                    return BUNDLE["FLASH_BIAS_N_033"];
                case 0x0000:
                    return BUNDLE["FLASH_BIAS_P_0"];
                case 0x000c:
                    return BUNDLE["FLASH_BIAS_P_033"];
                case 0x0010:
                    return BUNDLE["FLASH_BIAS_P_050"];
                case 0x0014:
                    return BUNDLE["FLASH_BIAS_P_067"];
                case 0x0020:
                    return BUNDLE["FLASH_BIAS_P_1"];
                case 0x002c:
                    return BUNDLE["FLASH_BIAS_P_133"];
                case 0x0030:
                    return BUNDLE["FLASH_BIAS_P_150"];
                case 0x0034:
                    return BUNDLE["FLASH_BIAS_P_167"];
                case 0x0040:
                    return BUNDLE["FLASH_BIAS_P_2"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Af Point Used Description.
        /// </summary>
        /// <returns>the Af Point Used Description.</returns>
        private string GetAfPointUsedDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE2_AF_POINT_USED))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE2_AF_POINT_USED);
            if ((aValue & 0x7) == 0)
            {
                return BUNDLE["RIGHT"];
            }
            else if ((aValue & 0x7) == 1)
            {
                return BUNDLE["CENTER"]; ;
            }
            else if ((aValue & 0x7) == 2)
            {
                return BUNDLE["LEFT"];
            }
            else
            {
                return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns White Balance Description.
        /// </summary>
        /// <returns>the White Balance Description.</returns>
        private string GetWhiteBalanceDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE2_WHITE_BALANCE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE2_WHITE_BALANCE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AUTO"];
                case 1:
                    return BUNDLE["SUNNY"];
                case 2:
                    return BUNDLE["CLOUDY"];
                case 3:
                    return BUNDLE["TUNGSTEN"];
                case 4:
                    return BUNDLE["FLOURESCENT"];
                case 5:
                    return BUNDLE["FLASH"];
                case 6:
                    return BUNDLE["CUSTOM"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Focus Mode 2 description.
        /// </summary>
        /// <returns>the Focus Mode 2 description</returns>
        private string GetFocusMode2Description()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_FOCUS_MODE_2))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_FOCUS_MODE_2);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["SINGLE"];
                case 1:
                    return BUNDLE["CONTINUOUS"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Flash Details description.
        /// </summary>
        /// <returns>the Flash Details description</returns>
        private string GetFlashDetailsDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_FLASH_DETAILS))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_FLASH_DETAILS);
            if (((aValue << 14) & 1) > 0)
            {
                return BUNDLE["EXTERNAL_E_TTL"];
            }
            if (((aValue << 13) & 1) > 0)
            {
                return BUNDLE["INTERNAL_FLASH"];
            }
            if (((aValue << 11) & 1) > 0)
            {
                return BUNDLE["FP_SYNC_USED"];
            }
            if (((aValue << 4) & 1) > 0)
            {
                return BUNDLE["FP_SYNC_ENABLED"];
            }
            return BUNDLE["UNKNOWN", aValue.ToString()];
        }

        /// <summary>
        /// Returns Focal Units Per Millimetre description.
        /// </summary>
        /// <returns>the Focal Units Per Millimetre description</returns>
        private string GetFocalUnitsPerMillimetreDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_FOCAL_UNITS_PER_MM))
                return "";
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_FOCAL_UNITS_PER_MM);
            if (aValue != 0)
            {
                return aValue.ToString();
            }
            else
            {
                return "";
            }
        }

        /// <summary>
        /// Returns Short Focal Length description.
        /// </summary>
        /// <returns>the Short Focal Length description</returns>
        private string GetShortFocalLengthDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_SHORT_FOCAL_LENGTH))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_SHORT_FOCAL_LENGTH);
            string units = GetFocalUnitsPerMillimetreDescription();
            return BUNDLE["FOCAL_LENGTH", aValue.ToString(), units];
        }

        /// <summary>
        /// Returns Long Focal Length description.
        /// </summary>
        /// <returns>the Long Focal Length description</returns>
        private string GetLongFocalLengthDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_LONG_FOCAL_LENGTH))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_LONG_FOCAL_LENGTH);
            string units = GetFocalUnitsPerMillimetreDescription();
            return BUNDLE["FOCAL_LENGTH", aValue.ToString(), units];
        }

        /// <summary>
        /// Returns Exposure Mode description.
        /// </summary>
        /// <returns>the Exposure Mode description</returns>
        private string GetExposureModeDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_EXPOSURE_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_EXPOSURE_MODE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["EASY_SHOOTING"];
                case 1:
                    return BUNDLE["PROGRAM"];
                case 2:
                    return BUNDLE["TV_PRIORITY"];
                case 3:
                    return BUNDLE["AV_PRIORITY"];
                case 4:
                    return BUNDLE["MANUAL"];
                case 5:
                    return BUNDLE["A_DEP"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Af Point Selected description.
        /// </summary>
        /// <returns>the Af Point Selected description</returns>
        private string GetAfPointSelectedDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_AF_POINT_SELECTED))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_AF_POINT_SELECTED);
            switch (aValue)
            {
                case 0x3000:
                    return BUNDLE["NONE_MF"];
                case 0x3001:
                    return BUNDLE["AUTO_SELECTED"];
                case 0x3002:
                    return BUNDLE["RIGHT"];
                case 0x3003:
                    return BUNDLE["CENTER"];
                case 0x3004:
                    return BUNDLE["LEFT"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Metering Mode description.
        /// </summary>
        /// <returns>the Metering Mode description</returns>
        private string GetMeteringModeDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_METERING_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_METERING_MODE);
            switch (aValue)
            {
                case 3:
                    return BUNDLE["EVALUATIVE"];
                case 4:
                    return BUNDLE["PARTIAL"];
                case 5:
                    return BUNDLE["CENTRE_WEIGHTED"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns ISO description.
        /// </summary>
        /// <returns>the ISO description</returns>
        private string GetIsoDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_ISO))
                return null;
            int aValue =
                _directory.GetInt(CanonMakernoteDirectory.TAG_CANON_STATE1_ISO);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["ISO_NOT_SPECIFIED"];
                case 15:
                    return BUNDLE["AUTO"];
                case 16:
                    return BUNDLE["ISO_50"];
                case 17:
                    return BUNDLE["ISO_100"];
                case 18:
                    return BUNDLE["ISO_200"];
                case 19:
                    return BUNDLE["ISO_400"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Sharpness description.
        /// </summary>
        /// <returns>the Sharpness description</returns>
        private string GetSharpnessDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_SHARPNESS))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_SHARPNESS);
            switch (aValue)
            {
                case 0xFFFF:
                    return BUNDLE["LOW"];
                case 0x000:
                    return BUNDLE["NORMAL"];
                case 0x001:
                    return BUNDLE["HIGH"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Saturation description.
        /// </summary>
        /// <returns>the Saturation description</returns>
        private string GetSaturationDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_SATURATION))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_SATURATION);
            switch (aValue)
            {
                case 0xFFFF:
                    return BUNDLE["LOW"];
                case 0x000:
                    return BUNDLE["NORMAL"];
                case 0x001:
                    return BUNDLE["HIGH"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Contrast description.
        /// </summary>
        /// <returns>the Contrast description</returns>
        private string GetContrastDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_CONTRAST))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_CONTRAST);
            switch (aValue)
            {
                case 0xFFFF:
                    return BUNDLE["LOW"];
                case 0x000:
                    return BUNDLE["NORMAL"];
                case 0x001:
                    return BUNDLE["HIGH"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Easy Shooting Mode description.
        /// </summary>
        /// <returns>the Easy Shooting Mode description</returns>
        private string GetEasyShootingModeDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_EASY_SHOOTING_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_EASY_SHOOTING_MODE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["FULL_AUTO"];
                case 1:
                    return BUNDLE["MANUAL"];
                case 2:
                    return BUNDLE["LANDSCAPE"];
                case 3:
                    return BUNDLE["FAST_SHUTTER"];
                case 4:
                    return BUNDLE["SLOW_SHUTTER"];
                case 5:
                    return BUNDLE["NIGHT"];
                case 6:
                    return BUNDLE["B_W"];
                case 7:
                    return BUNDLE["SEPIA"];
                case 8:
                    return BUNDLE["PORTRAIT"];
                case 9:
                    return BUNDLE["SPORTS"];
                case 10:
                    return BUNDLE["MACRO_CLOSEUP"];
                case 11:
                    return BUNDLE["PAN_FOCUS"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Image Size description.
        /// </summary>
        /// <returns>the Image Size description</returns>
        private string GetImageSizeDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_IMAGE_SIZE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_IMAGE_SIZE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["LARGE"];
                case 1:
                    return BUNDLE["MEDIUM"];
                case 2:
                    return BUNDLE["SMALL"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Focus Mode 1 description.
        /// </summary>
        /// <returns>the Focus Mode 1 description</returns>
        private string GetFocusMode1Description()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_FOCUS_MODE_1))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_FOCUS_MODE_1);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["ONE_SHOT"];
                case 1:
                    return BUNDLE["AI_SERVO"];
                case 2:
                    return BUNDLE["AI_FOCUS"];
                case 3:
                    return BUNDLE["MF"];
                case 4:
                    // TODO should check field 32 here (FOCUS_MODE_2)
                    return BUNDLE["SINGLE"];
                case 5:
                    return BUNDLE["CONTINUOUS"];
                case 6:
                    return BUNDLE["MF"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Continuous Drive Mode description.
        /// </summary>
        /// <returns>the Continuous Drive Mode description</returns>
        private string GetContinuousDriveModeDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory
                .TAG_CANON_STATE1_CONTINUOUS_DRIVE_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_CONTINUOUS_DRIVE_MODE);
            switch (aValue)
            {
                case 0:
                    if (_directory
                        .GetInt(
                        CanonMakernoteDirectory
                        .TAG_CANON_STATE1_SELF_TIMER_DELAY)
                        == 0)
                    {
                        return BUNDLE["SINGLE_SHOT"];
                    }
                    else
                    {
                        return BUNDLE["SINGLE_SHOT_WITH_SELF_TIMER"];
                    }
                case 1:
                    return BUNDLE["CONTINUOUS"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Flash Mode description.
        /// </summary>
        /// <returns>the Flash Mode description</returns>
        private string GetFlashModeDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_FLASH_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_FLASH_MODE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NO_FLASH_FIRED"];
                case 1:
                    return BUNDLE["AUTO"];
                case 2:
                    return BUNDLE["ON"];
                case 3:
                    return BUNDLE["RED_YEY_REDUCTION"];
                case 4:
                    return BUNDLE["SLOW_SYNCHRO"];
                case 5:
                    return BUNDLE["AUTO_AND_RED_YEY_REDUCTION"];
                case 6:
                    return BUNDLE["ON_AND_RED_YEY_REDUCTION"];
                case 16:
                    // note: this aValue not set on Canon D30
                    return BUNDLE["EXTERNAL_FLASH"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns Self Timer Delay description.
        /// </summary>
        /// <returns>the Self Timer Delay description</returns>
        private string GetSelfTimerDelayDescription()
        {
            if (!_directory
                .ContainsTag(
                CanonMakernoteDirectory.TAG_CANON_STATE1_SELF_TIMER_DELAY))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_SELF_TIMER_DELAY);
            if (aValue == 0)
            {
                return BUNDLE["SELF_TIMER_DELAY_NOT_USED"];
            }
            else
            {
                // TODO find an image that tests this calculation
                return BUNDLE["SELF_TIMER_DELAY", ((double)aValue * 0.1d).ToString()];
            }
        }

        /// <summary>
        /// Returns Macro Mode description.
        /// </summary>
        /// <returns>the Macro Mode description</returns>
        private string GetMacroModeDescription()
        {
            if (!_directory
                .ContainsTag(CanonMakernoteDirectory.TAG_CANON_STATE1_MACRO_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                CanonMakernoteDirectory.TAG_CANON_STATE1_MACRO_MODE);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["MACRO"];
                case 2:
                    return BUNDLE["NORMAL"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }
    }

    /// <summary>
    /// This class represents CASIO marker note.
    /// </summary>
    public class CasioMakernoteDirectory : Directory
    {
        public const int TAG_CASIO_RECORDING_MODE = 0x0001;
        public const int TAG_CASIO_QUALITY = 0x0002;
        public const int TAG_CASIO_FOCUSING_MODE = 0x0003;
        public const int TAG_CASIO_FLASH_MODE = 0x0004;
        public const int TAG_CASIO_FLASH_INTENSITY = 0x0005;
        public const int TAG_CASIO_OBJECT_DISTANCE = 0x0006;
        public const int TAG_CASIO_WHITE_BALANCE = 0x0007;
        public const int TAG_CASIO_UNKNOWN_1 = 0x0008;
        public const int TAG_CASIO_UNKNOWN_2 = 0x0009;
        public const int TAG_CASIO_DIGITAL_ZOOM = 0x000A;
        public const int TAG_CASIO_SHARPNESS = 0x000B;
        public const int TAG_CASIO_CONTRAST = 0x000C;
        public const int TAG_CASIO_SATURATION = 0x000D;
        public const int TAG_CASIO_UNKNOWN_3 = 0x000E;
        public const int TAG_CASIO_UNKNOWN_4 = 0x000F;
        public const int TAG_CASIO_UNKNOWN_5 = 0x0010;
        public const int TAG_CASIO_UNKNOWN_6 = 0x0011;
        public const int TAG_CASIO_UNKNOWN_7 = 0x0012;
        public const int TAG_CASIO_UNKNOWN_8 = 0x0013;
        public const int TAG_CASIO_CCD_SENSITIVITY = 0x0014;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("CasioMarkernote");

        protected static readonly IDictionary tagNameMap = CasioMakernoteDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();

            resu.Add(TAG_CASIO_CCD_SENSITIVITY, BUNDLE["TAG_CASIO_CCD_SENSITIVITY"]);
            resu.Add(TAG_CASIO_CONTRAST, BUNDLE["TAG_CASIO_CONTRAST"]);
            resu.Add(TAG_CASIO_DIGITAL_ZOOM, BUNDLE["TAG_CASIO_DIGITAL_ZOOM"]);
            resu.Add(TAG_CASIO_FLASH_INTENSITY, BUNDLE["TAG_CASIO_FLASH_INTENSITY"]);
            resu.Add(TAG_CASIO_FLASH_MODE, BUNDLE["TAG_CASIO_FLASH_MODE"]);
            resu.Add(TAG_CASIO_FOCUSING_MODE, BUNDLE["TAG_CASIO_FOCUSING_MODE"]);
            resu.Add(TAG_CASIO_OBJECT_DISTANCE, BUNDLE["TAG_CASIO_OBJECT_DISTANCE"]);
            resu.Add(TAG_CASIO_QUALITY, BUNDLE["TAG_CASIO_QUALITY"]);
            resu.Add(TAG_CASIO_RECORDING_MODE, BUNDLE["TAG_CASIO_RECORDING_MODE"]);
            resu.Add(TAG_CASIO_SATURATION, BUNDLE["TAG_CASIO_SATURATION"]);
            resu.Add(TAG_CASIO_SHARPNESS, BUNDLE["TAG_CASIO_SHARPNESS"]);
            resu.Add(TAG_CASIO_UNKNOWN_1, BUNDLE["TAG_CASIO_UNKNOWN_1"]);
            resu.Add(TAG_CASIO_UNKNOWN_2, BUNDLE["TAG_CASIO_UNKNOWN_2"]);
            resu.Add(TAG_CASIO_UNKNOWN_3, BUNDLE["TAG_CASIO_UNKNOWN_3"]);
            resu.Add(TAG_CASIO_UNKNOWN_4, BUNDLE["TAG_CASIO_UNKNOWN_4"]);
            resu.Add(TAG_CASIO_UNKNOWN_5, BUNDLE["TAG_CASIO_UNKNOWN_5"]);
            resu.Add(TAG_CASIO_UNKNOWN_6, BUNDLE["TAG_CASIO_UNKNOWN_6"]);
            resu.Add(TAG_CASIO_UNKNOWN_7, BUNDLE["TAG_CASIO_UNKNOWN_7"]);
            resu.Add(TAG_CASIO_UNKNOWN_8, BUNDLE["TAG_CASIO_UNKNOWN_8"]);
            resu.Add(TAG_CASIO_WHITE_BALANCE, BUNDLE["TAG_CASIO_WHITE_BALANCE"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public CasioMakernoteDirectory()
            : base()
        {
            this.SetDescriptor(new CasioMakernoteDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// Tag descriptor for a casio camera
    /// </summary>
    public class CasioMakernoteDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public CasioMakernoteDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case CasioMakernoteDirectory.TAG_CASIO_RECORDING_MODE:
                    return GetRecordingModeDescription();
                case CasioMakernoteDirectory.TAG_CASIO_QUALITY:
                    return GetQualityDescription();
                case CasioMakernoteDirectory.TAG_CASIO_FOCUSING_MODE:
                    return GetFocusingModeDescription();
                case CasioMakernoteDirectory.TAG_CASIO_FLASH_MODE:
                    return GetFlashModeDescription();
                case CasioMakernoteDirectory.TAG_CASIO_FLASH_INTENSITY:
                    return GetFlashIntensityDescription();
                case CasioMakernoteDirectory.TAG_CASIO_OBJECT_DISTANCE:
                    return GetObjectDistanceDescription();
                case CasioMakernoteDirectory.TAG_CASIO_WHITE_BALANCE:
                    return GetWhiteBalanceDescription();
                case CasioMakernoteDirectory.TAG_CASIO_DIGITAL_ZOOM:
                    return GetDigitalZoomDescription();
                case CasioMakernoteDirectory.TAG_CASIO_SHARPNESS:
                    return GetSharpnessDescription();
                case CasioMakernoteDirectory.TAG_CASIO_CONTRAST:
                    return GetContrastDescription();
                case CasioMakernoteDirectory.TAG_CASIO_SATURATION:
                    return GetSaturationDescription();
                case CasioMakernoteDirectory.TAG_CASIO_CCD_SENSITIVITY:
                    return GetCcdSensitivityDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Ccd Sensitivity Description.
        /// </summary>
        /// <returns>the Ccd Sensitivity Description.</returns>
        private string GetCcdSensitivityDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_CCD_SENSITIVITY))
                return null;
            int aValue =
                _directory.GetInt(
                CasioMakernoteDirectory.TAG_CASIO_CCD_SENSITIVITY);
            switch (aValue)
            {
                // these four for QV3000
                case 64:
                    return BUNDLE["NORMAL"];
                case 125:
                    return BUNDLE["CCD_P_1"];
                case 250:
                    return BUNDLE["CCD_P_2"];
                case 244:
                    return BUNDLE["CCD_P_3"];
                // these two for QV8000/2000
                case 80:
                    return BUNDLE["NORMAL"];
                case 100:
                    return BUNDLE["HIGH"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the saturation Description.
        /// </summary>
        /// <returns>the saturation Description.</returns>
        private string GetSaturationDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_SATURATION))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_SATURATION);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL"];
                case 1:
                    return BUNDLE["LOW"];
                case 2:
                    return BUNDLE["HIGH"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the contrast Description.
        /// </summary>
        /// <returns>the contrast Description.</returns>
        private string GetContrastDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_CONTRAST))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_CONTRAST);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL"];
                case 1:
                    return BUNDLE["LOW"];
                case 2:
                    return BUNDLE["HIGH"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the sharpness Description.
        /// </summary>
        /// <returns>the sharpness Description.</returns>
        private string GetSharpnessDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_SHARPNESS))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_SHARPNESS);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL"];
                case 1:
                    return BUNDLE["SOFT"]; ;
                case 2:
                    return BUNDLE["HARD"]; ;
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Digital Zoom Description.
        /// </summary>
        /// <returns>the Digital Zoom Description.</returns>
        private string GetDigitalZoomDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_DIGITAL_ZOOM))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_DIGITAL_ZOOM);
            switch (aValue)
            {
                case 65536:
                    return BUNDLE["NO_DIGITAL_ZOOM"];
                case 65537:
                    return BUNDLE["2_X_DIGITAL_ZOOM"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the White Balance Description.
        /// </summary>
        /// <returns>the White Balance Description.</returns>
        private string GetWhiteBalanceDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_WHITE_BALANCE))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_WHITE_BALANCE);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["AUTO"];
                case 2:
                    return BUNDLE["TUNGSTEN"];
                case 3:
                    return BUNDLE["DAYLIGHT"];
                case 4:
                    return BUNDLE["FLOURESCENT"];
                case 5:
                    return BUNDLE["SHADE"];
                case 129:
                    return BUNDLE["MANUAL"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Object Distance Description.
        /// </summary>
        /// <returns>the Object Distance Description.</returns>
        private string GetObjectDistanceDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_OBJECT_DISTANCE))
                return null;
            int aValue =
                _directory.GetInt(
                CasioMakernoteDirectory.TAG_CASIO_OBJECT_DISTANCE);
            return BUNDLE["DISTANCE_MM", aValue.ToString()];
        }

        /// <summary>
        /// Returns the Flash Intensity Description.
        /// </summary>
        /// <returns>the Flash Intensity Description.</returns>
        private string GetFlashIntensityDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_FLASH_INTENSITY))
                return null;
            int aValue =
                _directory.GetInt(
                CasioMakernoteDirectory.TAG_CASIO_FLASH_INTENSITY);
            switch (aValue)
            {
                case 11:
                    return BUNDLE["WEAK"];
                case 13:
                    return BUNDLE["NORMAL"];
                case 15:
                    return BUNDLE["STRONG"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Flash Mode Description.
        /// </summary>
        /// <returns>the Flash Mode Description.</returns>
        private string GetFlashModeDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_FLASH_MODE))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_FLASH_MODE);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["AUTO"];
                case 2:
                    return BUNDLE["ON"];
                case 3:
                    return BUNDLE["OFF"];
                case 4:
                    return BUNDLE["RED_YEY_REDUCTION"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Focusing Mode Description.
        /// </summary>
        /// <returns>the Focusing Mode Description.</returns>
        private string GetFocusingModeDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_FOCUSING_MODE))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_FOCUSING_MODE);
            switch (aValue)
            {
                case 2:
                    return BUNDLE["MACRO"];
                case 3:
                    return BUNDLE["AUTO_FOCUS"];
                case 4:
                    return BUNDLE["MANUAL_FOCUS"];
                case 5:
                    return BUNDLE["INFINITY"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the quality Description.
        /// </summary>
        /// <returns>the quality Description.</returns>
        private string GetQualityDescription()
        {
            if (!_directory.ContainsTag(CasioMakernoteDirectory.TAG_CASIO_QUALITY))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_QUALITY);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["ECONOMY"];
                case 2:
                    return BUNDLE["NORMAL"];
                case 3:
                    return BUNDLE["FINE"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Focussing Mode Description.
        /// </summary>
        /// <returns>the Focussing Mode Description.</returns>
        private string GetFocussingModeDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_FOCUSING_MODE))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_FOCUSING_MODE);
            switch (aValue)
            {
                case 2:
                    return BUNDLE["MACRO"];
                case 3:
                    return BUNDLE["AUTO_FOCUS"];
                case 4:
                    return BUNDLE["MANUAL_FOCUS"];
                case 5:
                    return BUNDLE["INFINITY"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Recording Mode Description.
        /// </summary>
        /// <returns>the Recording Mode Description.</returns>
        private string GetRecordingModeDescription()
        {
            if (!_directory
                .ContainsTag(CasioMakernoteDirectory.TAG_CASIO_RECORDING_MODE))
                return null;
            int aValue =
                _directory.GetInt(CasioMakernoteDirectory.TAG_CASIO_RECORDING_MODE);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["SINGLE_SHUTTER"];
                case 2:
                    return BUNDLE["PANORAMA"];
                case 3:
                    return BUNDLE["NIGHT_SCENE"];
                case 4:
                    return BUNDLE["PORTRAIT"];
                case 5:
                    return BUNDLE["LANDSCAPE"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }
    }

    /// <summary>
    /// The Fuji Film Makernote Directory
    /// </summary>
    public class FujiFilmMakernoteDirectory : Directory
    {
        public const int TAG_FUJIFILM_MAKERNOTE_VERSION = 0x0000;
        public const int TAG_FUJIFILM_QUALITY = 0x1000;
        public const int TAG_FUJIFILM_SHARPNESS = 0x1001;
        public const int TAG_FUJIFILM_WHITE_BALANCE = 0x1002;
        public const int TAG_FUJIFILM_COLOR = 0x1003;
        public const int TAG_FUJIFILM_TONE = 0x1004;
        public const int TAG_FUJIFILM_FLASH_MODE = 0x1010;
        public const int TAG_FUJIFILM_FLASH_STRENGTH = 0x1011;
        public const int TAG_FUJIFILM_MACRO = 0x1020;
        public const int TAG_FUJIFILM_FOCUS_MODE = 0x1021;
        public const int TAG_FUJIFILM_SLOW_SYNCHRO = 0x1030;
        public const int TAG_FUJIFILM_PICTURE_MODE = 0x1031;
        public const int TAG_FUJIFILM_UNKNOWN_1 = 0x1032;
        public const int TAG_FUJIFILM_CONTINUOUS_TAKING_OR_AUTO_BRACKETTING = 0x1100;
        public const int TAG_FUJIFILM_UNKNOWN_2 = 0x1200;
        public const int TAG_FUJIFILM_BLUR_WARNING = 0x1300;
        public const int TAG_FUJIFILM_FOCUS_WARNING = 0x1301;
        public const int TAG_FUJIFILM_AE_WARNING = 0x1302;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("FujiFilmMarkernote");
        protected static readonly IDictionary tagNameMap = FujiFilmMakernoteDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_FUJIFILM_AE_WARNING, BUNDLE["TAG_FUJIFILM_AE_WARNING"]);
            resu.Add(TAG_FUJIFILM_BLUR_WARNING, BUNDLE["TAG_FUJIFILM_BLUR_WARNING"]);
            resu.Add(TAG_FUJIFILM_COLOR, BUNDLE["TAG_FUJIFILM_COLOR"]);
            resu.Add(TAG_FUJIFILM_CONTINUOUS_TAKING_OR_AUTO_BRACKETTING, BUNDLE["TAG_FUJIFILM_CONTINUOUS_TAKING_OR_AUTO_BRACKETTING"]);
            resu.Add(TAG_FUJIFILM_FLASH_MODE, BUNDLE["TAG_FUJIFILM_FLASH_MODE"]);
            resu.Add(TAG_FUJIFILM_FLASH_STRENGTH, BUNDLE["TAG_FUJIFILM_FLASH_STRENGTH"]);
            resu.Add(TAG_FUJIFILM_FOCUS_MODE, BUNDLE["TAG_FUJIFILM_FOCUS_MODE"]);
            resu.Add(TAG_FUJIFILM_FOCUS_WARNING, BUNDLE["TAG_FUJIFILM_FOCUS_WARNING"]);
            resu.Add(TAG_FUJIFILM_MACRO, BUNDLE["TAG_FUJIFILM_MACRO"]);
            resu.Add(TAG_FUJIFILM_MAKERNOTE_VERSION, BUNDLE["TAG_FUJIFILM_MAKERNOTE_VERSION"]);
            resu.Add(TAG_FUJIFILM_PICTURE_MODE, BUNDLE["TAG_FUJIFILM_PICTURE_MODE"]);
            resu.Add(TAG_FUJIFILM_QUALITY, BUNDLE["TAG_FUJIFILM_QUALITY"]);
            resu.Add(TAG_FUJIFILM_SHARPNESS, BUNDLE["TAG_FUJIFILM_SHARPNESS"]);
            resu.Add(TAG_FUJIFILM_SLOW_SYNCHRO, BUNDLE["TAG_FUJIFILM_SLOW_SYNCHRO"]);
            resu.Add(TAG_FUJIFILM_TONE, BUNDLE["TAG_FUJIFILM_TONE"]);
            resu.Add(TAG_FUJIFILM_UNKNOWN_1, BUNDLE["TAG_FUJIFILM_UNKNOWN_1"]);
            resu.Add(TAG_FUJIFILM_UNKNOWN_2, BUNDLE["TAG_FUJIFILM_UNKNOWN_2"]);
            resu.Add(TAG_FUJIFILM_WHITE_BALANCE, BUNDLE["TAG_FUJIFILM_WHITE_BALANCE"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public FujiFilmMakernoteDirectory()
            : base()
        {
            this.SetDescriptor(new FujifilmMakernoteDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// Fujifilm's digicam added the MakerNote tag from the Year2000's model
    /// (e.g.Finepix1400, Finepix4700). It uses IFD format and start from ASCII character
    /// 'FUJIFILM', and next 4 bytes(aValue 0x000c) points the offSet to first IFD entry.
    /// Example of actual data structure is shown below.
    /// :0000: 46 55 4A 49 46 49 4C 4D-0C 00 00 00 0F 00 00 00 :0000: FUJIFILM........
    /// :0010: 07 00 04 00 00 00 30 31-33 30 00 10 02 00 08 00 :0010: ......0130......
    /// There are two big differences to the other manufacturers.
    /// - Fujifilm's Exif data uses Motorola align, but MakerNote ignores it and uses Intel align.
    /// - The other manufacturer's MakerNote counts the "offSet to data" from the first byte of
    ///   TIFF header (same as the other IFD), but Fujifilm counts it from the first byte of MakerNote itself.
    /// </summary>
    public class FujifilmMakernoteDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public FujifilmMakernoteDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_SHARPNESS:
                    return GetSharpnessDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_WHITE_BALANCE:
                    return GetWhiteBalanceDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_COLOR:
                    return GetColorDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_TONE:
                    return GetToneDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_FLASH_MODE:
                    return GetFlashModeDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_FLASH_STRENGTH:
                    return GetFlashStrengthDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_MACRO:
                    return GetMacroDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_FOCUS_MODE:
                    return GetFocusModeDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_SLOW_SYNCHRO:
                    return GetSlowSyncDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_PICTURE_MODE:
                    return GetPictureModeDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_CONTINUOUS_TAKING_OR_AUTO_BRACKETTING:
                    return GetContinuousTakingOrAutoBrackettingDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_BLUR_WARNING:
                    return GetBlurWarningDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_FOCUS_WARNING:
                    return GetFocusWarningDescription();
                case FujiFilmMakernoteDirectory.TAG_FUJIFILM_AE_WARNING:
                    return GetAutoExposureWarningDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Auto Exposure Description.
        /// </summary>
        /// <returns>the Auto Exposure Description.</returns>
        private string GetAutoExposureWarningDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_AE_WARNING))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_AE_WARNING);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AE_GOOD"];
                case 1:
                    return BUNDLE["OVER_EXPOSED"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Focus Warning Description.
        /// </summary>
        /// <returns>the Focus Warning Description.</returns>
        private string GetFocusWarningDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_FOCUS_WARNING))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_FOCUS_WARNING);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AUTO_FOCUS_GOOD"];
                case 1:
                    return BUNDLE["OUT_OF_FOCUS"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Blur Warning Description.
        /// </summary>
        /// <returns>the Blur Warning Description.</returns>
        private string GetBlurWarningDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_BLUR_WARNING))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_BLUR_WARNING);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NO_BLUR_WARNING"];
                case 1:
                    return BUNDLE["BLUR_WARNING"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Continuous Taking Or AutoBracketting Description.
        /// </summary>
        /// <returns>the Continuous Taking Or AutoBracketting Description.</returns>
        private string GetContinuousTakingOrAutoBrackettingDescription()
        {
            if (!_directory
                .ContainsTag(
                FujiFilmMakernoteDirectory
                .TAG_FUJIFILM_CONTINUOUS_TAKING_OR_AUTO_BRACKETTING))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory
                .TAG_FUJIFILM_CONTINUOUS_TAKING_OR_AUTO_BRACKETTING);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["OFF"];
                case 1:
                    return BUNDLE["ON"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Picture Mode Description.
        /// </summary>
        /// <returns>the Picture Mode Description.</returns>
        private string GetPictureModeDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_PICTURE_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_PICTURE_MODE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AUTO"];
                case 1:
                    return BUNDLE["PORTRAIT_SCENE"];
                case 2:
                    return BUNDLE["LANDSCAPE_SCENE"];
                case 4:
                    return BUNDLE["SPORTS_SCENE"];
                case 5:
                    return BUNDLE["NIGHT_SCENE"];
                case 6:
                    return BUNDLE["PROGRAM_AE"];
                case 256:
                    return BUNDLE["APERTURE_PRIORITY_AE"];
                case 512:
                    return BUNDLE["SHUTTER_PRIORITY_AE"];
                case 768:
                    return BUNDLE["MANUAL_EXPOSURE"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Slow Sync Description.
        /// </summary>
        /// <returns>the Slow Sync Description.</returns>
        private string GetSlowSyncDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_SLOW_SYNCHRO))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_SLOW_SYNCHRO);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["OFF"];
                case 1:
                    return BUNDLE["ON"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Focus Mode Description.
        /// </summary>
        /// <returns>the Focus Mode Description.</returns>
        private string GetFocusModeDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_FOCUS_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_FOCUS_MODE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AUTO_FOCUS"];
                case 1:
                    return BUNDLE["MANUAL_FOCUS"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Macro Description.
        /// </summary>
        /// <returns>the Macro Description.</returns>
        private string GetMacroDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_MACRO))
                return null;
            int aValue =
                _directory.GetInt(FujiFilmMakernoteDirectory.TAG_FUJIFILM_MACRO);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["OFF"];
                case 1:
                    return BUNDLE["ON"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Flash Strength Description.
        /// </summary>
        /// <returns>the Flash Strength Description.</returns>
        private string GetFlashStrengthDescription()
        {
            if (!_directory
                .ContainsTag(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_FLASH_STRENGTH))
                return null;
            Rational aValue =
                _directory.GetRational(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_FLASH_STRENGTH);
            return BUNDLE["FLASH_STRENGTH", aValue.ToSimpleString(false)];
        }

        /// <summary>
        /// Returns the Flash Mode Description.
        /// </summary>
        /// <returns>the Flash Mode Description.</returns>
        private string GetFlashModeDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_FLASH_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_FLASH_MODE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AUTO"];
                case 1:
                    return BUNDLE["ON"];
                case 2:
                    return BUNDLE["OFF"];
                case 3:
                    return BUNDLE["RED_YEY_REDUCTION"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Tone Description.
        /// </summary>
        /// <returns>the Tone Description.</returns>
        private string GetToneDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_TONE))
                return null;
            int aValue =
                _directory.GetInt(FujiFilmMakernoteDirectory.TAG_FUJIFILM_TONE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL_STD"];
                case 256:
                    return BUNDLE["HIGH_HARD"];
                case 512:
                    return BUNDLE["LOW_ORG"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Color Description.
        /// </summary>
        /// <returns>the Color Description.</returns>
        private string GetColorDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_COLOR))
                return null;
            int aValue =
                _directory.GetInt(FujiFilmMakernoteDirectory.TAG_FUJIFILM_COLOR);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL_STD"];
                case 256:
                    return BUNDLE["HIGH"];
                case 512:
                    return BUNDLE["LOW_ORG"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the White Balance Description.
        /// </summary>
        /// <returns>the White Balance Description.</returns>
        private string GetWhiteBalanceDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_WHITE_BALANCE))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_WHITE_BALANCE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AUTO"];
                case 256:
                    return BUNDLE["DAYLIGHT"];
                case 512:
                    return BUNDLE["CLOUDY"];
                case 768:
                    return BUNDLE["DAYLIGHTCOLOR_FLUORESCENCE"];
                case 769:
                    return BUNDLE["DAYWHITECOLOR_FLUORESCENCE"];
                case 770:
                    return BUNDLE["WHITE_FLUORESCENCE"];
                case 1024:
                    return BUNDLE["INCANDENSCENSE"];
                case 3840:
                    return BUNDLE["CUSTOM_WHITE_BALANCE"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Sharpness Description.
        /// </summary>
        /// <returns>the Sharpness Description.</returns>
        private string GetSharpnessDescription()
        {
            if (!_directory
                .ContainsTag(FujiFilmMakernoteDirectory.TAG_FUJIFILM_SHARPNESS))
                return null;
            int aValue =
                _directory.GetInt(
                FujiFilmMakernoteDirectory.TAG_FUJIFILM_SHARPNESS);
            switch (aValue)
            {
                case 1:
                case 2:
                    return BUNDLE["SOFT"];
                case 3:
                    return BUNDLE["NORMAL"];
                case 4:
                case 5:
                    return BUNDLE["HARD"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }
    }

    public abstract class NikonTypeMakernoteDirectory : Directory
    {
        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("NikonMarkernote");

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }
    }

    public class NikonType1MakernoteDirectory : NikonTypeMakernoteDirectory
    {
        // TYPE1 is for E-Series cameras prior to (not including) E990
        public const int TAG_NIKON_TYPE1_UNKNOWN_1 = 0x0002;
        public const int TAG_NIKON_TYPE1_QUALITY = 0x0003;
        public const int TAG_NIKON_TYPE1_COLOR_MODE = 0x0004;
        public const int TAG_NIKON_TYPE1_IMAGE_ADJUSTMENT = 0x0005;
        public const int TAG_NIKON_TYPE1_CCD_SENSITIVITY = 0x0006;
        public const int TAG_NIKON_TYPE1_WHITE_BALANCE = 0x0007;
        public const int TAG_NIKON_TYPE1_FOCUS = 0x0008;
        public const int TAG_NIKON_TYPE1_UNKNOWN_2 = 0x0009;
        public const int TAG_NIKON_TYPE1_DIGITAL_ZOOM = 0x000A;
        public const int TAG_NIKON_TYPE1_CONVERTER = 0x000B;
        public const int TAG_NIKON_TYPE1_UNKNOWN_3 = 0x0F00;

        protected static readonly IDictionary tagNameMap = NikonType1MakernoteDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_NIKON_TYPE1_CCD_SENSITIVITY, BUNDLE["TAG_NIKON_TYPE1_CCD_SENSITIVITY"]);
            resu.Add(TAG_NIKON_TYPE1_COLOR_MODE, BUNDLE["TAG_NIKON_TYPE1_COLOR_MODE"]);
            resu.Add(TAG_NIKON_TYPE1_DIGITAL_ZOOM, BUNDLE["TAG_NIKON_TYPE1_DIGITAL_ZOOM"]);
            resu.Add(TAG_NIKON_TYPE1_CONVERTER, BUNDLE["TAG_NIKON_TYPE1_CONVERTER"]);
            resu.Add(TAG_NIKON_TYPE1_FOCUS, BUNDLE["TAG_NIKON_TYPE1_FOCUS"]);
            resu.Add(TAG_NIKON_TYPE1_IMAGE_ADJUSTMENT, BUNDLE["TAG_NIKON_TYPE1_IMAGE_ADJUSTMENT"]);
            resu.Add(TAG_NIKON_TYPE1_QUALITY, BUNDLE["TAG_NIKON_TYPE1_QUALITY"]);
            resu.Add(TAG_NIKON_TYPE1_UNKNOWN_1, BUNDLE["TAG_NIKON_TYPE1_UNKNOWN_1"]);
            resu.Add(TAG_NIKON_TYPE1_UNKNOWN_2, BUNDLE["TAG_NIKON_TYPE1_UNKNOWN_2"]);
            resu.Add(TAG_NIKON_TYPE1_UNKNOWN_3, BUNDLE["TAG_NIKON_TYPE1_UNKNOWN_3"]);
            resu.Add(TAG_NIKON_TYPE1_WHITE_BALANCE, BUNDLE["TAG_NIKON_TYPE1_WHITE_BALANCE"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public NikonType1MakernoteDirectory()
            : base()
        {
            this.SetDescriptor(new NikonType1MakernoteDescriptor(this));
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// There are 3 formats of Nikon's MakerNote. MakerNote of E700/E800/E900/E900S/E910/E950 starts
    /// from ASCII string "Nikon". Data format is the same as IFD, but it starts from offSet 0x08.
    /// This is the same as Olympus except start string. Example of actual data structure is shown below.
    /// :0000: 4E 69 6B 6F 6E 00 01 00-05 00 02 00 02 00 06 00 Nikon...........
    /// :0010: 00 00 EC 02 00 00 03 00-03 00 01 00 00 00 06 00 ................
    /// </summary>
    public class NikonType1MakernoteDescriptor : TagDescriptor
    {

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public NikonType1MakernoteDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_QUALITY:
                    return GetQualityDescription();
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_COLOR_MODE:
                    return GetColorModeDescription();
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_IMAGE_ADJUSTMENT:
                    return GetImageAdjustmentDescription();
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_CCD_SENSITIVITY:
                    return GetCcdSensitivityDescription();
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_WHITE_BALANCE:
                    return GetWhiteBalanceDescription();
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_FOCUS:
                    return GetFocusDescription();
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_DIGITAL_ZOOM:
                    return GetDigitalZoomDescription();
                case NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_CONVERTER:
                    return GetConverterDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Converter Description.
        /// </summary>
        /// <returns>the Converter Description.</returns>
        private string GetConverterDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_CONVERTER))
                return null;
            int aValue =
                _directory.GetInt(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_CONVERTER);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NONE"];
                case 1:
                    return BUNDLE["FISHEYE_CONVERTER"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Digital Zoom Description.
        /// </summary>
        /// <returns>the Digital Zoom Description.</returns>
        private string GetDigitalZoomDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_DIGITAL_ZOOM))
                return null;
            Rational aValue =
                _directory.GetRational(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_DIGITAL_ZOOM);
            if (aValue.GetNumerator() == 0)
            {
                return BUNDLE["NO_DIGITAL_ZOOM"];
            }
            return BUNDLE["DIGITAL_ZOOM", aValue.ToSimpleString(true)];
        }

        /// <summary>
        /// Returns the Focus Description.
        /// </summary>
        /// <returns>the Focus Description.</returns>
        private string GetFocusDescription()
        {
            if (!_directory
                .ContainsTag(NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_FOCUS))
                return null;
            Rational aValue =
                _directory.GetRational(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_FOCUS);
            if (aValue.GetNumerator() == 1 && aValue.GetDenominator() == 0)
            {
                return BUNDLE["INFINITE"];
            }
            return aValue.ToSimpleString(true);
        }

        /// <summary>
        /// Returns the White Balance Description.
        /// </summary>
        /// <returns>the White Balance Description.</returns>
        private string GetWhiteBalanceDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_WHITE_BALANCE))
                return null;
            int aValue =
                _directory.GetInt(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_WHITE_BALANCE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["AUTO"];
                case 1:
                    return BUNDLE["PRESET"];
                case 2:
                    return BUNDLE["DAYLIGHT"];
                case 3:
                    return BUNDLE["INCANDESCENSE"];
                case 4:
                    return BUNDLE["FLOURESCENT"];
                case 5:
                    return BUNDLE["CLOUDY"];
                case 6:
                    return BUNDLE["SPEEDLIGHT"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Ccd Sensitivity Description.
        /// </summary>
        /// <returns>the Ccd Sensitivity Description.</returns>
        private string GetCcdSensitivityDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_CCD_SENSITIVITY))
                return null;
            int aValue =
                _directory.GetInt(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_CCD_SENSITIVITY);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["ISO", "80"];
                case 2:
                    return BUNDLE["ISO", "160"];
                case 4:
                    return BUNDLE["ISO", "320"];
                case 5:
                    return BUNDLE["ISO", "100"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Image Adjustment Description.
        /// </summary>
        /// <returns>the Image Adjustment Description.</returns>
        private string GetImageAdjustmentDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_IMAGE_ADJUSTMENT))
                return null;
            int aValue =
                _directory.GetInt(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_IMAGE_ADJUSTMENT);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL"];
                case 1:
                    return BUNDLE["BRIGHT_P"];
                case 2:
                    return BUNDLE["BRIGHT_M"];
                case 3:
                    return BUNDLE["CONTRAST_P"];
                case 4:
                    return BUNDLE["CONTRAST_M"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Color Mode Description.
        /// </summary>
        /// <returns>the Color Mode Description.</returns>
        private string GetColorModeDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_COLOR_MODE))
                return null;
            int aValue =
                _directory.GetInt(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_COLOR_MODE);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["COLOR"];
                case 2:
                    return BUNDLE["MONOCHROME"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Quality Description.
        /// </summary>
        /// <returns>the Quality Description.</returns>
        private string GetQualityDescription()
        {
            if (!_directory
                .ContainsTag(NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_QUALITY))
                return null;
            int aValue =
                _directory.GetInt(
                NikonType1MakernoteDirectory.TAG_NIKON_TYPE1_QUALITY);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["VGA_BASIC"];
                case 2:
                    return BUNDLE["VGA_NORMAL"];
                case 3:
                    return BUNDLE["VGA_FINE"];
                case 4:
                    return BUNDLE["SXGA_BASIC"];
                case 5:
                    return BUNDLE["SXGA_NORMAL"];
                case 6:
                    return BUNDLE["SXGA_FINE"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }
    }

    public class NikonType2MakernoteDirectory : NikonTypeMakernoteDirectory
    {
        // TYPE2 is for E990, D1 and later
        public const int TAG_NIKON_TYPE2_UNKNOWN_1 = 0x0001;
        public const int TAG_NIKON_TYPE2_ISO_SETTING = 0x0002;
        public const int TAG_NIKON_TYPE2_COLOR_MODE = 0x0003;
        public const int TAG_NIKON_TYPE2_QUALITY = 0x0004;
        public const int TAG_NIKON_TYPE2_WHITE_BALANCE = 0x0005;
        public const int TAG_NIKON_TYPE2_IMAGE_SHARPENING = 0x0006;
        public const int TAG_NIKON_TYPE2_FOCUS_MODE = 0x0007;
        public const int TAG_NIKON_TYPE2_FLASH_SETTING = 0x0008;
        public const int TAG_NIKON_TYPE2_UNKNOWN_2 = 0x000A;
        public const int TAG_NIKON_TYPE2_ISO_SELECTION = 0x000F;
        public const int TAG_NIKON_TYPE2_IMAGE_ADJUSTMENT = 0x0080;
        public const int TAG_NIKON_TYPE2_ADAPTER = 0x0082;
        public const int TAG_NIKON_TYPE2_MANUAL_FOCUS_DISTANCE = 0x0085;
        public const int TAG_NIKON_TYPE2_DIGITAL_ZOOM = 0x0086;
        public const int TAG_NIKON_TYPE2_AF_FOCUS_POSITION = 0x0088;
        public const int TAG_NIKON_TYPE2_DATA_DUMP = 0x0010;

        protected static readonly IDictionary tagNameMap = NikonType2MakernoteDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_NIKON_TYPE2_ADAPTER, BUNDLE["TAG_NIKON_TYPE2_ADAPTER"]);
            resu.Add(TAG_NIKON_TYPE2_AF_FOCUS_POSITION, BUNDLE["TAG_NIKON_TYPE2_AF_FOCUS_POSITION"]);
            resu.Add(TAG_NIKON_TYPE2_COLOR_MODE, BUNDLE["TAG_NIKON_TYPE2_COLOR_MODE"]);
            resu.Add(TAG_NIKON_TYPE2_DATA_DUMP, BUNDLE["TAG_NIKON_TYPE2_DATA_DUMP"]);
            resu.Add(TAG_NIKON_TYPE2_DIGITAL_ZOOM, BUNDLE["TAG_NIKON_TYPE2_DIGITAL_ZOOM"]);
            resu.Add(TAG_NIKON_TYPE2_FLASH_SETTING, BUNDLE["TAG_NIKON_TYPE2_FLASH_SETTING"]);
            resu.Add(TAG_NIKON_TYPE2_FOCUS_MODE, BUNDLE["TAG_NIKON_TYPE2_FOCUS_MODE"]);
            resu.Add(TAG_NIKON_TYPE2_IMAGE_ADJUSTMENT, BUNDLE["TAG_NIKON_TYPE2_IMAGE_ADJUSTMENT"]);
            resu.Add(TAG_NIKON_TYPE2_IMAGE_SHARPENING, BUNDLE["TAG_NIKON_TYPE2_IMAGE_SHARPENING"]);
            resu.Add(TAG_NIKON_TYPE2_ISO_SELECTION, BUNDLE["TAG_NIKON_TYPE2_ISO_SELECTION"]);
            resu.Add(TAG_NIKON_TYPE2_ISO_SETTING, BUNDLE["TAG_NIKON_TYPE2_ISO_SETTING"]);
            resu.Add(TAG_NIKON_TYPE2_MANUAL_FOCUS_DISTANCE, BUNDLE["TAG_NIKON_TYPE2_MANUAL_FOCUS_DISTANCE"]);
            resu.Add(TAG_NIKON_TYPE2_QUALITY, BUNDLE["TAG_NIKON_TYPE2_QUALITY"]);
            resu.Add(TAG_NIKON_TYPE2_UNKNOWN_1, BUNDLE["TAG_NIKON_TYPE2_UNKNOWN_1"]);
            resu.Add(TAG_NIKON_TYPE2_UNKNOWN_2, BUNDLE["TAG_NIKON_TYPE2_UNKNOWN_2"]);
            resu.Add(TAG_NIKON_TYPE2_WHITE_BALANCE, BUNDLE["TAG_NIKON_TYPE2_WHITE_BALANCE"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public NikonType2MakernoteDirectory()
            : base()
        {
            this.SetDescriptor(new NikonType2MakernoteDescriptor(this));
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// Tag descriptor for Nikon
    /// </summary>
    public class NikonType2MakernoteDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public NikonType2MakernoteDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_ISO_SETTING:
                    return GetIsoSettingDescription();
                case NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_DIGITAL_ZOOM:
                    return GetDigitalZoomDescription();
                case NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_AF_FOCUS_POSITION:
                    return GetAutoFocusPositionDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Auto Focus Position Description.
        /// </summary>
        /// <returns>the Auto Focus Position Description.</returns>
        private string GetAutoFocusPositionDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType2MakernoteDirectory
                .TAG_NIKON_TYPE2_AF_FOCUS_POSITION))
                return null;
            int[] values =
                _directory.GetIntArray(
                NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_AF_FOCUS_POSITION);
            if (values.Length != 4
                || values[0] != 0
                || values[2] != 0
                || values[3] != 0)
            {
                return BUNDLE["UNKNOWN", _directory.GetString(NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_AF_FOCUS_POSITION)];
            }
            switch (values[1])
            {
                case 0:
                    return BUNDLE["CENTER"];
                case 1:
                    return BUNDLE["TOP"];
                case 2:
                    return BUNDLE["BOTTOM"];
                case 3:
                    return BUNDLE["LEFT"];
                case 4:
                    return BUNDLE["RIGHT"];
                default:
                    return BUNDLE["UNKNOWN", values[1].ToString()];
            }
        }

        /// <summary>
        /// Returns the Digital Zoom Description.
        /// </summary>
        /// <returns>the Digital Zoom Description.</returns>
        private string GetDigitalZoomDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_DIGITAL_ZOOM))
                return null;
            Rational rational =
                _directory.GetRational(
                NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_DIGITAL_ZOOM);
            if (rational.IntValue() == 1)
            {
                return BUNDLE["NO_DIGITAL_ZOOM"];
            }
            return BUNDLE["DIGITAL_ZOOM", rational.ToSimpleString(true)];
        }

        /// <summary>
        /// Returns the Iso Setting Description.
        /// </summary>
        /// <returns>the Iso Setting Description.</returns>
        private string GetIsoSettingDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_ISO_SETTING))
                return null;
            int[] values =
                _directory.GetIntArray(
                NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_ISO_SETTING);
            if (values[0] != 0 || values[1] == 0)
            {
                return BUNDLE["UNKNOWN", _directory.GetString(NikonType2MakernoteDirectory.TAG_NIKON_TYPE2_ISO_SETTING)];
            }
            return BUNDLE["ISO", values[1].ToString()];
        }
    }

    /// <summary>
    /// The type-3 directory is for D-Series cameras such as the D1 and D100.
    /// Thanks to Fabrizio Giudici for publishing his reverse-engineering of the D1 makernote data.
    /// http://www.timelesswanderings.net/equipment/D100/NEF.html
    ///
    /// Additional sample images have been observed, and their tag values recorded in doc
    /// comments for each tag's field. New tags have subsequently been added since Fabrizio's observations.
    /// </summary>
    public class NikonType3MakernoteDirectory : NikonTypeMakernoteDirectory
    {
        /// <summary>
        /// Values observed
        /// - 0200
        /// </summary>
        public const int TAG_NIKON_TYPE3_FIRMWARE_VERSION = 1;

        /// <summary>
        /// Values observed
        /// - 0 250
        /// - 0 400
        /// </summary>
        public const int TAG_NIKON_TYPE3_ISO_1 = 2;

        /// <summary>
        /// Values observed
        /// - FILE
        /// - RAW
        /// </summary>
        public const int TAG_NIKON_TYPE3_FILE_FORMAT = 4;

        /// <summary>
        /// Values observed
        /// - AUTO
        /// - SUNNY
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE = 5;

        /// <summary>
        /// Values observed
        /// - AUTO
        /// - NORMAL
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAMERA_SHARPENING = 6;

        /// <summary>
        /// Values observed
        /// - AF-S
        /// </summary>
        public const int TAG_NIKON_TYPE3_AF_TYPE = 7;

        /// <summary>
        /// Values observed
        /// - NORMAL
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_17 = 8;

        /// <summary>
        /// Values observed
        /// -
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_18 = 9;

        /// <summary>
        /// Values observed
        /// - 0
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_FINE = 11;

        /// <summary>
        /// Values observed
        /// - 2.25882352 1.76078431 0.0 0.0
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_RB_COEFF = 12;

        /// <summary>
        /// Values observed
        /// -
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_1 = 13;

        /// <summary>
        /// Values observed
        /// -
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_2 = 14;

        /// <summary>
        /// Values observed
        /// - 914
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_3 = 17;

        /// <summary>
        /// Values observed
        /// -
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_19 = 18;

        /// <summary>
        /// Values observed
        /// - 0 250
        /// </summary>
        public const int TAG_NIKON_TYPE3_ISO_2 = 19;

        /// <summary>
        /// Values observed
        /// - AUTO
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAMERA_TONE_COMPENSATION = 129;

        /// <summary>
        /// Values observed
        /// - 6
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_4 = 131;

        /// <summary>
        /// Values observed
        /// - 240/10 850/10 35/10 45/10
        /// </summary>
        public const int TAG_NIKON_TYPE3_LENS = 132;

        /// <summary>
        /// Values observed
        /// - 0
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_5 = 135;

        /// <summary>
        /// Values observed
        /// -
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_6 = 136;

        /// <summary>
        /// Values observed
        /// - 0
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_7 = 137;

        /// <summary>
        /// Values observed
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_8 = 139;

        /// <summary>
        /// Values observed
        /// - 0
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_20 = 138;

        /// <summary>
        /// Values observed
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_9 = 140;

        /// <summary>
        /// Values observed
        /// - MODE1
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAMERA_COLOR_MODE = 141;

        /// <summary>
        /// Values observed
        /// - NATURAL
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_10 = 144;

        public const int TAG_NIKON_TYPE3_UNKNOWN_11 = 145;

        /// <summary>
        /// Values observed
        /// - 0
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAMERA_HUE_ADJUSTMENT = 146;

        /// <summary>
        /// Values observed
        /// - OFF
        /// </summary>
        public const int TAG_NIKON_TYPE3_NOISE_REDUCTION = 149;

        public const int TAG_NIKON_TYPE3_UNKNOWN_12 = 151;

        /// <summary>
        /// Values observed
        /// - 0100fht@7b,4x,D"Y
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_13 = 152;

        /// <summary>
        /// Values observed
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_14 = 153;

        /// <summary>
        /// Values observed
        /// - 78/10 78/10
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_15 = 154;

        /// <summary>
        /// Values observed
        /// </summary>
        public const int TAG_NIKON_TYPE3_CAPTURE_EDITOR_DATA = 3585;

        /// <summary>
        /// Values observed
        /// </summary>
        public const int TAG_NIKON_TYPE3_UNKNOWN_16 = 3600;

        protected static readonly IDictionary tagNameMap = NikonType3MakernoteDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_NIKON_TYPE3_FIRMWARE_VERSION, BUNDLE["TAG_NIKON_TYPE3_FIRMWARE_VERSION"]);
            resu.Add(TAG_NIKON_TYPE3_ISO_1, BUNDLE["TAG_NIKON_TYPE3_ISO_1"]);
            resu.Add(TAG_NIKON_TYPE3_FILE_FORMAT, BUNDLE["TAG_NIKON_TYPE3_FILE_FORMAT"]);
            resu.Add(TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE, BUNDLE["TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE"]);
            resu.Add(TAG_NIKON_TYPE3_CAMERA_SHARPENING, BUNDLE["TAG_NIKON_TYPE3_CAMERA_SHARPENING"]);
            resu.Add(TAG_NIKON_TYPE3_AF_TYPE, BUNDLE["TAG_NIKON_TYPE3_AF_TYPE"]);
            resu.Add(TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_FINE, BUNDLE["TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_FINE"]);
            resu.Add(TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_RB_COEFF, BUNDLE["TAG_NIKON_TYPE3_CAMERA_WHITE_BALANCE_RB_COEFF"]);
            resu.Add(TAG_NIKON_TYPE3_ISO_2, BUNDLE["TAG_NIKON_TYPE3_ISO_2"]);
            resu.Add(TAG_NIKON_TYPE3_CAMERA_TONE_COMPENSATION, BUNDLE["TAG_NIKON_TYPE3_CAMERA_TONE_COMPENSATION"]);
            resu.Add(TAG_NIKON_TYPE3_LENS, BUNDLE["TAG_NIKON_TYPE3_LENS"]);
            resu.Add(TAG_NIKON_TYPE3_CAMERA_COLOR_MODE, BUNDLE["TAG_NIKON_TYPE3_CAMERA_COLOR_MODE"]);
            resu.Add(TAG_NIKON_TYPE3_CAMERA_HUE_ADJUSTMENT, BUNDLE["TAG_NIKON_TYPE3_CAMERA_HUE_ADJUSTMENT"]);
            resu.Add(TAG_NIKON_TYPE3_NOISE_REDUCTION, BUNDLE["TAG_NIKON_TYPE3_NOISE_REDUCTION"]);
            resu.Add(TAG_NIKON_TYPE3_CAPTURE_EDITOR_DATA, BUNDLE["TAG_NIKON_TYPE3_CAPTURE_EDITOR_DATA"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_1, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_1"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_2, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_2"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_3, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_3"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_4, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_4"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_5, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_5"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_6, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_6"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_7, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_7"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_8, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_8"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_9, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_9"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_10, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_10"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_11, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_11"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_12, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_12"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_13, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_13"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_14, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_14"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_15, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_15"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_16, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_16"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_17, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_17"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_18, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_18"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_19, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_19"]);
            resu.Add(TAG_NIKON_TYPE3_UNKNOWN_20, BUNDLE["TAG_NIKON_TYPE3_UNKNOWN_20"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public NikonType3MakernoteDirectory()
            : base()
        {
            this.SetDescriptor(new NikonType3MakernoteDescriptor(this));
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// There are 3 formats of Nikon's MakerNote. MakerNote of E700/E800/E900/E900S/E910/E950
    /// starts from ASCII string "Nikon".
    /// Data format is the same as IFD, but it starts from offSet 0x08. T
    /// his is the same as Olympus except start string.
    /// Example of actual data structure is shown below.
    ///
    /// :0000: 4E 69 6B 6F 6E 00 02 00-00 00 4D 4D 00 2A 00 00 Nikon....MM.*...
    /// :0010: 00 08 00 1E 00 01 00 07-00 00 00 04 30 32 30 30 ............0200
    /// </summary>
    public class NikonType3MakernoteDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public NikonType3MakernoteDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_LENS:
                    return GetLensDescription();
                case NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_CAMERA_HUE_ADJUSTMENT:
                    return GetHueAdjustmentDescription();
                case NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_CAMERA_COLOR_MODE:
                    return GetColorModeDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Lens Description.
        /// </summary>
        /// <returns>the Lens Description.</returns>
        public string GetLensDescription()
        {
            if (!_directory
                .ContainsTag(NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_LENS))
                return null;

            Rational[] lensValues =
                _directory.GetRationalArray(
                NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_LENS);

            if (lensValues.Length != 4)
                return _directory.GetString(
                    NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_LENS);

            string[] tab = new string[] {lensValues[0].IntValue().ToString(),
                                            lensValues[1].IntValue().ToString(),
                                            lensValues[2].FloatValue().ToString(),
                                            lensValues[3].FloatValue().ToString()};

            return BUNDLE["LENS", tab];
        }

        /// <summary>
        /// Returns the Hue Adjustment Description.
        /// </summary>
        /// <returns>the Hue Adjustment Description.</returns>
        public string GetHueAdjustmentDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType3MakernoteDirectory
                .TAG_NIKON_TYPE3_CAMERA_HUE_ADJUSTMENT))
                return null;

            return BUNDLE["DEGREES", _directory.GetString(NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_CAMERA_HUE_ADJUSTMENT)];
        }

        /// <summary>
        /// Returns the Color Mode Description.
        /// </summary>
        /// <returns>the Color Mode Description.</returns>
        public string GetColorModeDescription()
        {
            if (!_directory
                .ContainsTag(
                NikonType3MakernoteDirectory
                .TAG_NIKON_TYPE3_CAMERA_COLOR_MODE))
                return null;

            string raw =
                _directory.GetString(
                NikonType3MakernoteDirectory.TAG_NIKON_TYPE3_CAMERA_COLOR_MODE);
            if (raw.StartsWith("MODE1"))
            {
                return BUNDLE["MODE_I_SRGB"];
            }

            return raw;
        }
    }

    public class OlympusMakernoteDirectory : Directory
    {
        public const int TAG_OLYMPUS_SPECIAL_MODE = 0x0200;
        public const int TAG_OLYMPUS_JPEG_QUALITY = 0x0201;
        public const int TAG_OLYMPUS_MACRO_MODE = 0x0202;
        public const int TAG_OLYMPUS_UNKNOWN_1 = 0x0203;
        public const int TAG_OLYMPUS_DIGI_ZOOM_RATIO = 0x0204;
        public const int TAG_OLYMPUS_UNKNOWN_2 = 0x0205;
        public const int TAG_OLYMPUS_UNKNOWN_3 = 0x0206;
        public const int TAG_OLYMPUS_FIRMWARE_VERSION = 0x0207;
        public const int TAG_OLYMPUS_PICT_INFO = 0x0208;
        public const int TAG_OLYMPUS_CAMERA_ID = 0x0209;
        public const int TAG_OLYMPUS_DATA_DUMP = 0x0F00;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("OlympusMarkernote");
        protected static readonly IDictionary tagNameMap = OlympusMakernoteDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_OLYMPUS_SPECIAL_MODE, BUNDLE["TAG_OLYMPUS_SPECIAL_MODE"]);
            resu.Add(TAG_OLYMPUS_JPEG_QUALITY, BUNDLE["TAG_OLYMPUS_JPEG_QUALITY"]);
            resu.Add(TAG_OLYMPUS_MACRO_MODE, BUNDLE["TAG_OLYMPUS_MACRO_MODE"]);
            resu.Add(TAG_OLYMPUS_UNKNOWN_1, BUNDLE["TAG_OLYMPUS_UNKNOWN_1"]);
            resu.Add(TAG_OLYMPUS_DIGI_ZOOM_RATIO, BUNDLE["TAG_OLYMPUS_DIGI_ZOOM_RATIO"]);
            resu.Add(TAG_OLYMPUS_UNKNOWN_2, BUNDLE["TAG_OLYMPUS_UNKNOWN_2"]);
            resu.Add(TAG_OLYMPUS_UNKNOWN_3, BUNDLE["TAG_OLYMPUS_UNKNOWN_3"]);
            resu.Add(TAG_OLYMPUS_FIRMWARE_VERSION, BUNDLE["TAG_OLYMPUS_FIRMWARE_VERSION"]);
            resu.Add(TAG_OLYMPUS_PICT_INFO, BUNDLE["TAG_OLYMPUS_PICT_INFO"]);
            resu.Add(TAG_OLYMPUS_CAMERA_ID, BUNDLE["TAG_OLYMPUS_CAMERA_ID"]);
            resu.Add(TAG_OLYMPUS_DATA_DUMP, BUNDLE["TAG_OLYMPUS_DATA_DUMP"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public OlympusMakernoteDirectory()
            : base()
        {
            this.SetDescriptor(new OlympusMakernoteDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// Tag descriptor for Olympus
    /// </summary>
    public class OlympusMakernoteDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public OlympusMakernoteDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case OlympusMakernoteDirectory.TAG_OLYMPUS_SPECIAL_MODE:
                    return GetSpecialModeDescription();
                case OlympusMakernoteDirectory.TAG_OLYMPUS_JPEG_QUALITY:
                    return GetJpegQualityDescription();
                case OlympusMakernoteDirectory.TAG_OLYMPUS_MACRO_MODE:
                    return GetMacroModeDescription();
                case OlympusMakernoteDirectory.TAG_OLYMPUS_DIGI_ZOOM_RATIO:
                    return GetDigiZoomRatioDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Returns the Digi Zoom Ratio Description.
        /// </summary>
        /// <returns>the Digi Zoom Ratio Description.</returns>
        private string GetDigiZoomRatioDescription()
        {
            if (!_directory
                .ContainsTag(OlympusMakernoteDirectory.TAG_OLYMPUS_DIGI_ZOOM_RATIO))
                return null;
            int aValue =
                _directory.GetInt(
                OlympusMakernoteDirectory.TAG_OLYMPUS_DIGI_ZOOM_RATIO);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL"];
                case 2:
                    return BUNDLE["DIGITAL_2X_ZOOM"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Macro Mode Description.
        /// </summary>
        /// <returns>the Macro Mode Description.</returns>
        private string GetMacroModeDescription()
        {
            if (!_directory
                .ContainsTag(OlympusMakernoteDirectory.TAG_OLYMPUS_MACRO_MODE))
                return null;
            int aValue =
                _directory.GetInt(OlympusMakernoteDirectory.TAG_OLYMPUS_MACRO_MODE);
            switch (aValue)
            {
                case 0:
                    return BUNDLE["NORMAL_NO_MACRO"];
                case 1:
                    return BUNDLE["MACRO"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Jpeg Quality Description.
        /// </summary>
        /// <returns>the Jpeg Quality Description.</returns>
        private string GetJpegQualityDescription()
        {
            if (!_directory
                .ContainsTag(OlympusMakernoteDirectory.TAG_OLYMPUS_JPEG_QUALITY))
                return null;
            int aValue =
                _directory.GetInt(
                OlympusMakernoteDirectory.TAG_OLYMPUS_JPEG_QUALITY);
            switch (aValue)
            {
                case 1:
                    return BUNDLE["SQ"];
                case 2:
                    return BUNDLE["HQ"];
                case 3:
                    return BUNDLE["SHQ"];
                default:
                    return BUNDLE["UNKNOWN", aValue.ToString()];
            }
        }

        /// <summary>
        /// Returns the Special Mode Description.
        /// </summary>
        /// <returns>the Special Mode Description.</returns>
        private string GetSpecialModeDescription()
        {
            if (!_directory
                .ContainsTag(OlympusMakernoteDirectory.TAG_OLYMPUS_SPECIAL_MODE))
                return null;
            int[] values =
                _directory.GetIntArray(
                OlympusMakernoteDirectory.TAG_OLYMPUS_SPECIAL_MODE);
            StringBuilder desc = new StringBuilder();
            switch (values[0])
            {
                case 0:
                    desc.Append(BUNDLE["NORMAL_PICTURE_TAKING_MODE"]);
                    break;
                case 1:
                    desc.Append(BUNDLE["UNKNOWN_PICTURE_TAKING_MODE"]);
                    break;
                case 2:
                    desc.Append(BUNDLE["FAST_PICTURE_TAKING_MODE"]);
                    break;
                case 3:
                    desc.Append(BUNDLE["PANORAMA_PICTURE_TAKING_MODE"]);
                    break;
                default:
                    desc.Append(BUNDLE["UNKNOWN_PICTURE_TAKING_MODE"]);
                    break;
            }
            desc.Append(" - ");
            switch (values[1])
            {
                case 0:
                    desc.Append(BUNDLE["UNKNOWN_SEQUENCE_NUMBER"]);
                    break;
                default:
                    desc.Append(BUNDLE["X_RD_IN_A_SEQUENCE", values[1].ToString()]);
                    break;
            }
            switch (values[2])
            {
                case 1:
                    desc.Append(BUNDLE["LEFT_TO_RIGHT_PAN_DIR"]);
                    break;
                case 2:
                    desc.Append(BUNDLE["RIGHT_TO_LEFT_PAN_DIR"]);
                    break;
                case 3:
                    desc.Append(BUNDLE["BOTTOM_TO_TOP_PAN_DIR"]);
                    break;
                case 4:
                    desc.Append(BUNDLE["TOP_TO_BOTTOM_PAN_DIR"]);
                    break;
            }
            return desc.ToString();
        }
    }
}

namespace Com.Drew.Metadata.Iptc
{
    /// <summary>
    /// The Iptc Directory class
    /// </summary>
    public class IptcDirectory : Directory
    {
        public const int TAG_RECORD_VERSION = 0x0200;
        public const int TAG_CAPTION = 0x0278;
        public const int TAG_WRITER = 0x027a;
        public const int TAG_HEADLINE = 0x0269;
        public const int TAG_SPECIAL_INSTRUCTIONS = 0x0228;
        public const int TAG_BY_LINE = 0x0250;
        public const int TAG_BY_LINE_TITLE = 0x0255;
        public const int TAG_CREDIT = 0x026e;
        public const int TAG_SOURCE = 0x0273;
        public const int TAG_OBJECT_NAME = 0x0205;
        public const int TAG_DATE_CREATED = 0x0237;
        public const int TAG_CITY = 0x025a;
        public const int TAG_PROVINCE_OR_STATE = 0x025f;
        public const int TAG_COUNTRY_OR_PRIMARY_LOCATION = 0x0265;
        public const int TAG_ORIGINAL_TRANSMISSION_REFERENCE = 0x0267;
        public const int TAG_CATEGORY = 0x020f;
        public const int TAG_SUPPLEMENTAL_CATEGORIES = 0x0214;
        public const int TAG_URGENCY = 0x0200 | 10;
        public const int TAG_KEYWORDS = 0x0200 | 25;
        public const int TAG_COPYRIGHT_NOTICE = 0x0274;
        public const int TAG_RELEASE_DATE = 0x0200 | 30;
        public const int TAG_RELEASE_TIME = 0x0200 | 35;
        public const int TAG_TIME_CREATED = 0x0200 | 60;
        public const int TAG_ORIGINATING_PROGRAM = 0x0200 | 65;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("IptcMarkernote");
        protected static readonly IDictionary tagNameMap = IptcDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_RECORD_VERSION, BUNDLE["TAG_RECORD_VERSION"]);
            resu.Add(TAG_CAPTION, BUNDLE["TAG_CAPTION"]);
            resu.Add(TAG_WRITER, BUNDLE["TAG_WRITER"]);
            resu.Add(TAG_HEADLINE, BUNDLE["TAG_HEADLINE"]);
            resu.Add(TAG_SPECIAL_INSTRUCTIONS, BUNDLE["TAG_SPECIAL_INSTRUCTIONS"]);
            resu.Add(TAG_BY_LINE, BUNDLE["TAG_BY_LINE"]);
            resu.Add(TAG_BY_LINE_TITLE, BUNDLE["TAG_BY_LINE_TITLE"]);
            resu.Add(TAG_CREDIT, BUNDLE["TAG_CREDIT"]);
            resu.Add(TAG_SOURCE, BUNDLE["TAG_SOURCE"]);
            resu.Add(TAG_OBJECT_NAME, BUNDLE["TAG_OBJECT_NAME"]);
            resu.Add(TAG_DATE_CREATED, BUNDLE["TAG_DATE_CREATED"]);
            resu.Add(TAG_CITY, BUNDLE["TAG_CITY"]);
            resu.Add(TAG_PROVINCE_OR_STATE, BUNDLE["TAG_PROVINCE_OR_STATE"]);
            resu.Add(TAG_COUNTRY_OR_PRIMARY_LOCATION, BUNDLE["TAG_COUNTRY_OR_PRIMARY_LOCATION"]);
            resu.Add(TAG_ORIGINAL_TRANSMISSION_REFERENCE, BUNDLE["TAG_ORIGINAL_TRANSMISSION_REFERENCE"]);
            resu.Add(TAG_CATEGORY, BUNDLE["TAG_CATEGORY"]);
            resu.Add(TAG_SUPPLEMENTAL_CATEGORIES, BUNDLE["TAG_SUPPLEMENTAL_CATEGORIES"]);
            resu.Add(TAG_URGENCY, BUNDLE["TAG_URGENCY"]);
            resu.Add(TAG_KEYWORDS, BUNDLE["TAG_KEYWORDS"]);
            resu.Add(TAG_COPYRIGHT_NOTICE, BUNDLE["TAG_COPYRIGHT_NOTICE"]);
            resu.Add(TAG_RELEASE_DATE, BUNDLE["TAG_RELEASE_DATE"]);
            resu.Add(TAG_RELEASE_TIME, BUNDLE["TAG_RELEASE_TIME"]);
            resu.Add(TAG_TIME_CREATED, BUNDLE["TAG_TIME_CREATED"]);
            resu.Add(TAG_ORIGINATING_PROGRAM, BUNDLE["TAG_ORIGINATING_PROGRAM"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public IptcDirectory()
            : base()
        {
            this.SetDescriptor(new IptcDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }
    }

    /// <summary>
    /// The Iptc reader class
    /// </summary>
    public class IptcReader : MetadataReader
    {
        /*
            public const int DIRECTORY_IPTC = 2;

            public const int ENVELOPE_RECORD = 1;
            public const int APPLICATION_RECORD_2 = 2;
            public const int APPLICATION_RECORD_3 = 3;
            public const int APPLICATION_RECORD_4 = 4;
            public const int APPLICATION_RECORD_5 = 5;
            public const int APPLICATION_RECORD_6 = 6;
            public const int PRE_DATA_RECORD = 7;
            public const int DATA_RECORD = 8;
            public const int POST_DATA_RECORD = 9;
        */

        /// <summary>
        /// The Iptc data segment
        /// </summary>
        private readonly byte[] _data;

        /// <summary>
        /// Creates a new IptcReader for the specified Jpeg jpegFile.
        /// </summary>
        /// <param name="jpegFile">where to read</param>
        public IptcReader(FileInfo jpegFile)
            : this(
            new JpegSegmentReader(jpegFile).ReadSegment(
            JpegSegmentReader.SEGMENT_APPD))
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="data">the data to read</param>
        public IptcReader(byte[] data)
        {
            _data = data;
        }

        /// <summary>
        /// Performs the Iptc data extraction, returning a new instance of Metadata.
        /// </summary>
        /// <returns>a new instance of Metadata</returns>
        public Metadata Extract()
        {
            return Extract(new Metadata());
        }

        /// <summary>
        /// Extracts metadata
        /// </summary>
        /// <param name="metadata">where to add metadata</param>
        /// <returns>the metadata found</returns>
        public Metadata Extract(Metadata metadata)
        {
            if (_data == null)
            {
                return metadata;
            }

            Directory directory = metadata.GetDirectory(typeof(Com.Drew.Metadata.Iptc.IptcDirectory));

            // find start of data
            int offset = 0;
            try
            {
                while (offset < _data.Length - 1 && Get32Bits(offset) != 0x1c02)
                {
                    offset++;
                }
            }
            catch (MetadataException)
            {
                directory.AddError(
                    "Couldn't find start of Iptc data (invalid segment)");
                return metadata;
            }

            // for each tag
            while (offset < _data.Length)
            {
                // identifies start of a tag
                if (_data[offset] != 0x1c)
                {
                    break;
                }
                // we need at least five bytes left to read a tag
                if ((offset + 5) >= _data.Length)
                {
                    break;
                }

                offset++;

                int directoryType;
                int tagType;
                int tagByteCount;
                try
                {
                    directoryType = _data[offset++];
                    tagType = _data[offset++];
                    tagByteCount = Get32Bits(offset);
                }
                catch (MetadataException)
                {
                    directory.AddError(
                        "Iptc data segment ended mid-way through tag descriptor");
                    return metadata;
                }
                offset += 2;
                if ((offset + tagByteCount) > _data.Length)
                {
                    directory.AddError(
                        "data for tag extends beyond end of iptc segment");
                    break;
                }

                ProcessTag(directory, directoryType, tagType, offset, tagByteCount);
                offset += tagByteCount;
            }

            return metadata;
        }

        /// <summary>
        /// Returns an int calculated from two bytes of data at the specified offset (MSB, LSB).
        /// </summary>
        /// <param name="offset">position within the data buffer to read first byte</param>
        /// <returns>the 32 bit int value, between 0x0000 and 0xFFFF</returns>
        private int Get32Bits(int offset)
        {
            if (offset >= _data.Length)
            {
                throw new MetadataException("Attempt to read bytes from outside Iptc data buffer");
            }
            return ((_data[offset] & 255) << 8) | (_data[offset + 1] & 255);
        }

        /// <summary>
        /// This method serves as marsheller of objects for dataset.
        /// It converts from IPTC octets to relevant java object.
        /// </summary>
        /// <param name="directory">the directory</param>
        /// <param name="directoryType">the directory type</param>
        /// <param name="tagType">the tag type</param>
        /// <param name="offset">the offset</param>
        /// <param name="tagByteCount">the tag byte count</param>
        private void ProcessTag(
            Directory directory,
            int directoryType,
            int tagType,
            int offset,
            int tagByteCount)
        {
            int tagIdentifier = tagType | (directoryType << 8);

            if (tagIdentifier == IptcDirectory.TAG_RECORD_VERSION)
            {
                // short
                short shortValue =
                    (short)((_data[offset] << 8) | _data[offset + 1]);
                directory.SetObject(tagIdentifier, shortValue);
                return;
            }
            else if (tagIdentifier == IptcDirectory.TAG_URGENCY)
            {
                // byte
                directory.SetObject(tagIdentifier, _data[offset]);
                return;
            }
            else if (tagIdentifier == IptcDirectory.TAG_RELEASE_DATE || tagIdentifier == IptcDirectory.TAG_DATE_CREATED)
            {
                // Date object
                if (tagByteCount >= 8)
                {
                    String dateStr = Utils.Decode(_data, offset, tagByteCount, false);
                    try
                    {
                        int year = Convert.ToInt32(dateStr.Substring(0, 4));
                        int month = Convert.ToInt32(dateStr.Substring(4, 2)); //No -1 here;
                        int day = Convert.ToInt32(dateStr.Substring(6, 2));
                        DateTime date = new DateTime(year, month, day);
                        directory.SetObject(tagIdentifier, date);
                        return;
                    }
                    catch (FormatException)
                    {
                        // fall through and we'll store whatever was there as a String
                    }
                }
            }
            else if (tagIdentifier == IptcDirectory.TAG_RELEASE_TIME || tagIdentifier == IptcDirectory.TAG_TIME_CREATED)
            {
                // time...
            }

            // If no special handling by now, treat it as a string
            String str;
            if (tagByteCount < 1)
            {
                str = "";
            }
            else
            {
                str = Utils.Decode(_data, offset, tagByteCount, false);
            }
            if (directory.ContainsTag(tagIdentifier))
            {
                String[] oldStrings;
                String[] newStrings;
                try
                {
                    oldStrings = directory.GetStringArray(tagIdentifier);
                }
                catch (MetadataException)
                {
                    oldStrings = null;
                }
                if (oldStrings == null)
                {
                    newStrings = new String[1];
                }
                else
                {
                    newStrings = new String[oldStrings.Length + 1];
                    for (int i = 0; i < oldStrings.Length; i++)
                    {
                        newStrings[i] = oldStrings[i];
                    }
                }
                newStrings[newStrings.Length - 1] = str;
                directory.SetObject(tagIdentifier, newStrings);
            }
            else
            {
                directory.SetObject(tagIdentifier, str);
            }
        }
    }

    /// <summary>
    /// Tag descriptor for IPTC
    /// </summary>
    public class IptcDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public IptcDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            return _directory.GetString(tagType);
        }
    }
}

namespace Com.Drew.Metadata.Jpeg
{
    /// <summary>
    /// The Jpeg Directory class
    /// </summary>
    public class JpegDirectory : Directory
    {
        /// <summary>
        /// This is in bits/sample, usually 8 (12 and 16 not supported by most software).
        /// </summary>
        public const int TAG_JPEG_DATA_PRECISION = 0;

        /// <summary>
        /// The image's height.  Necessary for decoding the image, so it should always be there.
        /// </summary>
        public const int TAG_JPEG_IMAGE_HEIGHT = 1;

        /// <summary>
        /// The image's width.  Necessary for decoding the image, so it should always be there.
        /// </summary>
        public const int TAG_JPEG_IMAGE_WIDTH = 3;

        /// <summary>
        /// Usually 1 = grey scaled, 3 = color YcbCr or YIQ, 4 = color CMYK Each component TAG_COMPONENT_DATA_[1-4],
        /// has the following meaning: component Id(1byte)(1 = Y, 2 = Cb, 3 = Cr, 4 = I, 5 = Q),
        /// sampling factors (1byte) (bit 0-3 vertical., 4-7 horizontal.),
        /// quantization table number (1 byte).
        /// This info is from http://www.funducode.com/freec/Fileformats/format3/format3b.htm
        /// </summary>
        public const int TAG_JPEG_NUMBER_OF_COMPONENTS = 5;

        // NOTE!  Component tag type int values must increment in steps of 1

        /// <summary>
        /// the first of a possible 4 color components.  Number of components specified in TAG_JPEG_NUMBER_OF_COMPONENTS.
        /// </summary>
        public const int TAG_JPEG_COMPONENT_DATA_1 = 6;

        /// <summary>
        /// the second of a possible 4 color components.  Number of components specified in TAG_JPEG_NUMBER_OF_COMPONENTS.
        /// </summary>
        public const int TAG_JPEG_COMPONENT_DATA_2 = 7;

        /// <summary>
        /// the third of a possible 4 color components.  Number of components specified in TAG_JPEG_NUMBER_OF_COMPONENTS.
        /// </summary>
        public const int TAG_JPEG_COMPONENT_DATA_3 = 8;

        /// <summary>
        /// the fourth of a possible 4 color components.  Number of components specified in TAG_JPEG_NUMBER_OF_COMPONENTS.
        /// </summary>
        public const int TAG_JPEG_COMPONENT_DATA_4 = 9;

        protected static readonly ResourceBundle BUNDLE = new ResourceBundle("JpegMarkernote");
        protected static readonly IDictionary tagNameMap = JpegDirectory.InitTagMap();

        /// <summary>
        /// Initialize the tag map.
        /// </summary>
        /// <returns>the tag map</returns>
        private static IDictionary InitTagMap()
        {
            IDictionary resu = new Hashtable();
            resu.Add(TAG_JPEG_DATA_PRECISION, BUNDLE["TAG_JPEG_DATA_PRECISION"]);
            resu.Add(TAG_JPEG_IMAGE_WIDTH, BUNDLE["TAG_JPEG_IMAGE_WIDTH"]);
            resu.Add(TAG_JPEG_IMAGE_HEIGHT, BUNDLE["TAG_JPEG_IMAGE_HEIGHT"]);
            resu.Add(TAG_JPEG_NUMBER_OF_COMPONENTS, BUNDLE["TAG_JPEG_NUMBER_OF_COMPONENTS"]);
            resu.Add(TAG_JPEG_COMPONENT_DATA_1, BUNDLE["TAG_JPEG_COMPONENT_DATA_1"]);
            resu.Add(TAG_JPEG_COMPONENT_DATA_2, BUNDLE["TAG_JPEG_COMPONENT_DATA_2"]);
            resu.Add(TAG_JPEG_COMPONENT_DATA_3, BUNDLE["TAG_JPEG_COMPONENT_DATA_3"]);
            resu.Add(TAG_JPEG_COMPONENT_DATA_4, BUNDLE["TAG_JPEG_COMPONENT_DATA_4"]);
            return resu;
        }

        /// <summary>
        /// Constructor of the object.
        /// </summary>
        public JpegDirectory()
            : base()
        {
            this.SetDescriptor(new JpegDescriptor(this));
        }

        /// <summary>
        /// Provides the name of the directory, for display purposes.  E.g. Exif
        /// </summary>
        /// <returns>the name of the directory</returns>
        public override string GetName()
        {
            return BUNDLE["MARKER_NOTE_NAME"];
        }

        /// <summary>
        /// Provides the map of tag names, hashed by tag type identifier.
        /// </summary>
        /// <returns>the map of tag names</returns>
        protected override IDictionary GetTagNameMap()
        {
            return tagNameMap;
        }

        /**
         *
         * @param componentNumber
         * @return
         */

        /// <summary>
        /// Gets the component
        /// </summary>
        /// <param name="componentNumber">The zero-based index of the component.  This number is normally between 0 and 3. Use GetNumberOfComponents for bounds-checking.</param>
        /// <returns>the JpegComponent</returns>
        public JpegComponent GetComponent(int componentNumber)
        {
            int tagType = JpegDirectory.TAG_JPEG_COMPONENT_DATA_1 + componentNumber;

            JpegComponent component = (JpegComponent)GetObject(tagType);

            return component;
        }

        /// <summary>
        /// Gets image width
        /// </summary>
        /// <returns>image width</returns>
        public int GetImageWidth()
        {
            return GetInt(JpegDirectory.TAG_JPEG_IMAGE_WIDTH);
        }

        /// <summary>
        /// Gets image height
        /// </summary>
        /// <returns>image height</returns>
        public int GetImageHeight()
        {
            return GetInt(JpegDirectory.TAG_JPEG_IMAGE_HEIGHT);
        }

        /// <summary>
        /// Gets the Number Of Components
        /// </summary>
        /// <returns>the Number Of Components</returns>
        public int GetNumberOfComponents()
        {
            return GetInt(JpegDirectory.TAG_JPEG_NUMBER_OF_COMPONENTS);
        }
    }

    /// <summary>
    /// The Jpeg component class
    /// </summary>
    [Serializable]
    public class JpegComponent
    {
        private int _componentId;
        private int _samplingFactorByte;
        private int _quantizationTableNumber;

        /// <summary>
        /// The constructor of the object
        /// </summary>
        /// <param name="componentId">the component id</param>
        /// <param name="samplingFactorByte">the sampling factor byte</param>
        /// <param name="quantizationTableNumber">the quantization table number</param>
        public JpegComponent(
            int componentId,
            int samplingFactorByte,
            int quantizationTableNumber)
            : base()
        {
            _componentId = componentId;
            _samplingFactorByte = samplingFactorByte;
            _quantizationTableNumber = quantizationTableNumber;
        }

        /// <summary>
        /// Gets the component id
        /// </summary>
        /// <returns>the component id</returns>
        public int GetComponentId()
        {
            return _componentId;
        }

        /// <summary>
        /// The component name
        /// </summary>
        /// <returns>The component name</returns>
        public string GetComponentName()
        {
            switch (_componentId)
            {
                case 1:
                    return "Y";
                case 2:
                    return "Cb";
                case 3:
                    return "Cr";
                case 4:
                    return "I";
                case 5:
                    return "Q";
            }

            throw new MetadataException("Unsupported component id: " + _componentId);
        }

        /// <summary>
        /// Gets the Quantization Table Number
        /// </summary>
        /// <returns>the Quantization Table Number</returns>
        public int GetQuantizationTableNumber()
        {
            return _quantizationTableNumber;
        }

        /// <summary>
        /// Gets the Horizontal Sampling Factor
        /// </summary>
        /// <returns>the Horizontal Sampling Factor</returns>
        public int GetHorizontalSamplingFactor()
        {
            return _samplingFactorByte & 0x0F;
        }

        /// <summary>
        /// Gets the Vertical Sampling Factor
        /// </summary>
        /// <returns>the Vertical Sampling Factor</returns>
        public int GetVerticalSamplingFactor()
        {
            return (_samplingFactorByte >> 4) & 0x0F;
        }
    }

    /// <summary>
    /// The JPEG reader class
    /// </summary>
    public class JpegReader : MetadataReader
    {
        /// <summary>
        /// The SOF0 data segment.
        /// </summary>
        private byte[] _data;

        /// <summary>
        /// Creates a new IptcReader for the specified Jpeg jpegFile.
        /// </summary>
        /// <param name="jpegFile">where to read</param>
        public JpegReader(FileInfo jpegFile)
            : this(
            new JpegSegmentReader(jpegFile).ReadSegment(
            JpegSegmentReader.SEGMENT_SOF0))
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="data">the data to read</param>
        public JpegReader(byte[] data)
        {
            _data = data;
        }

        /// <summary>
        /// Performs the Exif data extraction, returning a new instance of Metadata.
        /// </summary>
        /// <returns>a new instance of Metadata</returns>
        public Metadata Extract()
        {
            return Extract(new Metadata());
        }

        /// <summary>
        /// Extracts metadata
        /// </summary>
        /// <param name="metadata">where to add metadata</param>
        /// <returns>the metadata found</returns>
        public Metadata Extract(Metadata metadata)
        {
            if (_data == null)
            {
                return metadata;
            }

            JpegDirectory directory =
                (JpegDirectory)metadata.GetDirectory(typeof(Com.Drew.Metadata.Jpeg.JpegDirectory));

            try
            {
                // data precision
                int dataPrecision =
                    Get16Bits(JpegDirectory.TAG_JPEG_DATA_PRECISION);
                directory.SetObject(
                    JpegDirectory.TAG_JPEG_DATA_PRECISION,
                    dataPrecision);

                // process height
                int height = Get32Bits(JpegDirectory.TAG_JPEG_IMAGE_HEIGHT);
                directory.SetObject(JpegDirectory.TAG_JPEG_IMAGE_HEIGHT, height);

                // process width
                int width = Get32Bits(JpegDirectory.TAG_JPEG_IMAGE_WIDTH);
                directory.SetObject(JpegDirectory.TAG_JPEG_IMAGE_WIDTH, width);

                // number of components
                int numberOfComponents =
                    Get16Bits(JpegDirectory.TAG_JPEG_NUMBER_OF_COMPONENTS);
                directory.SetObject(
                    JpegDirectory.TAG_JPEG_NUMBER_OF_COMPONENTS,
                    numberOfComponents);

                // for each component, there are three bytes of data:
                // 1 - Component ID: 1 = Y, 2 = Cb, 3 = Cr, 4 = I, 5 = Q
                // 2 - Sampling factors: bit 0-3 vertical, 4-7 horizontal
                // 3 - Quantization table number
                int offset = 6;
                for (int i = 0; i < numberOfComponents; i++)
                {
                    int componentId = Get16Bits(offset++);
                    int samplingFactorByte = Get16Bits(offset++);
                    int quantizationTableNumber = Get16Bits(offset++);
                    JpegComponent component =
                        new JpegComponent(
                        componentId,
                        samplingFactorByte,
                        quantizationTableNumber);
                    directory.SetObject(
                        JpegDirectory.TAG_JPEG_COMPONENT_DATA_1 + i,
                        component);
                }

            }
            catch (MetadataException me)
            {
                directory.AddError("MetadataException: " + me);
            }

            return metadata;
        }

        /// <summary>
        /// Returns an int calculated from two bytes of data at the specified offset (MSB, LSB).
        /// </summary>
        /// <param name="offset">position within the data buffer to read first byte</param>
        /// <returns>the 32 bit int value, between 0x0000 and 0xFFFF</returns>
        private int Get32Bits(int offset)
        {
            if (offset + 1 >= _data.Length)
            {
                throw new MetadataException("Attempt to read bytes from outside Jpeg segment data buffer");
            }

            return ((_data[offset] & 255) << 8) | (_data[offset + 1] & 255);
        }

        /// <summary>
        /// Returns an int calculated from one byte of data at the specified offset.
        /// </summary>
        /// <param name="offset">position within the data buffer to read byte</param>
        /// <returns>the 16 bit int value, between 0x00 and 0xFF</returns>
        private int Get16Bits(int offset)
        {
            if (offset >= _data.Length)
            {
                throw new MetadataException("Attempt to read bytes from outside Jpeg segment data buffer");
            }

            return (_data[offset] & 255);
        }
    }

    /// <summary>
    /// Tag descriptor for Jpeg
    /// </summary>
    public class JpegDescriptor : TagDescriptor
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="directory">a directory</param>
        public JpegDescriptor(Directory directory)
            : base(directory)
        {
        }

        /// <summary>
        /// Returns a descriptive value of the the specified tag for this image.
        /// Where possible, known values will be substituted here in place of the raw tokens actually
        /// kept in the Exif segment.
        /// If no substitution is available, the value provided by GetString(int) will be returned.
        /// This and GetString(int) are the only 'get' methods that won't throw an exception.
        /// </summary>
        /// <param name="tagType">the tag to find a description for</param>
        /// <returns>a description of the image's value for the specified tag, or null if the tag hasn't been defined.</returns>
        public override string GetDescription(int tagType)
        {
            switch (tagType)
            {
                case JpegDirectory.TAG_JPEG_COMPONENT_DATA_1:
                    return GetComponentDataDescription(0);
                case JpegDirectory.TAG_JPEG_COMPONENT_DATA_2:
                    return GetComponentDataDescription(1);
                case JpegDirectory.TAG_JPEG_COMPONENT_DATA_3:
                    return GetComponentDataDescription(2);
                case JpegDirectory.TAG_JPEG_COMPONENT_DATA_4:
                    return GetComponentDataDescription(3);
                case JpegDirectory.TAG_JPEG_DATA_PRECISION:
                    return GetDataPrecisionDescription();
                case JpegDirectory.TAG_JPEG_IMAGE_HEIGHT:
                    return GetImageHeightDescription();
                case JpegDirectory.TAG_JPEG_IMAGE_WIDTH:
                    return GetImageWidthDescription();
                default:
                    return _directory.GetString(tagType);
            }
        }

        /// <summary>
        /// Gets the image width description
        /// </summary>
        /// <returns>the image width description</returns>
        public string GetImageWidthDescription()
        {
            return BUNDLE["PIXELS", _directory.GetString(JpegDirectory.TAG_JPEG_IMAGE_WIDTH)];
        }

        /// <summary>
        /// Gets the image height description
        /// </summary>
        /// <returns>the image height description</returns>
        public string GetImageHeightDescription()
        {
            return BUNDLE["PIXELS", _directory.GetString(JpegDirectory.TAG_JPEG_IMAGE_HEIGHT)];
        }

        /// <summary>
        /// Gets the Data Precision description
        /// </summary>
        /// <returns>the Data Precision description</returns>
        public string GetDataPrecisionDescription()
        {
            return BUNDLE["BITS", _directory.GetString(JpegDirectory.TAG_JPEG_DATA_PRECISION)];
        }

        /// <summary>
        /// Gets the Component Data description
        /// </summary>
        /// <param name="componentNumber">the component number</param>
        /// <returns>the Component Data description</returns>
        public string GetComponentDataDescription(int componentNumber)
        {
            JpegComponent component =
                ((JpegDirectory)_directory).GetComponent(componentNumber);
            if (component == null)
            {
                throw new MetadataException("No Jpeg component exists with number " + componentNumber);
            }

            // {0} component: Quantization table {1}, Sampling factors {2} horiz/{3} vert
            string[] tab = new string[] {component.GetComponentName(),
                                            component.GetQuantizationTableNumber().ToString(),
                                            component.GetHorizontalSamplingFactor().ToString(),
                                            component.GetVerticalSamplingFactor().ToString()};

            return BUNDLE["COMPONENT_DATA", tab];
        }
    }
}

namespace Com.Drew.Imaging.Jpg
{
    /// <summary>
    /// Will analyze a stream form an image
    /// </summary>
    public class JpegSegmentReader
    {
        private FileInfo file;

        private byte[] data;

        private Stream stream;

        private IDictionary segmentDataMap;

        private readonly static byte SEGMENT_SOS = (byte)0xDA;

        private readonly static byte MARKER_EOI = (byte)0xD9;

        public readonly static byte SEGMENT_APP0 = (byte)0xE0;
        public readonly static byte SEGMENT_APP1 = (byte)0xE1;
        public readonly static byte SEGMENT_APP2 = (byte)0xE2;
        public readonly static byte SEGMENT_APP3 = (byte)0xE3;
        public readonly static byte SEGMENT_APP4 = (byte)0xE4;
        public readonly static byte SEGMENT_APP5 = (byte)0xE5;
        public readonly static byte SEGMENT_APP6 = (byte)0xE6;
        public readonly static byte SEGMENT_APP7 = (byte)0xE7;
        public readonly static byte SEGMENT_APP8 = (byte)0xE8;
        public readonly static byte SEGMENT_APP9 = (byte)0xE9;
        public readonly static byte SEGMENT_APPA = (byte)0xEA;
        public readonly static byte SEGMENT_APPB = (byte)0xEB;
        public readonly static byte SEGMENT_APPC = (byte)0xEC;
        public readonly static byte SEGMENT_APPD = (byte)0xED;
        public readonly static byte SEGMENT_APPE = (byte)0xEE;
        public readonly static byte SEGMENT_APPF = (byte)0xEF;

        public readonly static byte SEGMENT_SOI = (byte)0xD8;
        public readonly static byte SEGMENT_DQT = (byte)0xDB;
        public readonly static byte SEGMENT_DHT = (byte)0xC4;
        public readonly static byte SEGMENT_SOF0 = (byte)0xC0;
        public readonly static byte SEGMENT_COM = (byte)0xFE;

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="aFile">where to read</param>
        public JpegSegmentReader(FileInfo aFile)
            : base()
        {
            this.file = aFile;
            this.data = null;
            this.stream = null;
            this.ReadSegments();
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="aFileContents">where to read</param>
        public JpegSegmentReader(byte[] aFileContents)
        {
            this.file = null;
            this.stream = null;
            this.data = aFileContents;
            this.ReadSegments();
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="aStream">where to read</param>
        public JpegSegmentReader(Stream aStream)
        {
            this.stream = aStream;
            this.file = null;
            this.data = null;
            this.ReadSegments();
        }

        /// <summary>
        /// Reads the first instance of a given Jpeg segment, returning the contents as a byte array.
        /// </summary>
        /// <param name="segmentMarker">the byte identifier for the desired segment</param>
        /// <returns>the byte array if found, else null</returns>
        /// <exception cref="JpegProcessingException">for any problems processing the Jpeg data</exception>
        public byte[] ReadSegment(byte segmentMarker)
        {
            return ReadSegment(segmentMarker, 0);
        }

        /// <summary>
        /// Reads the first instance of a given Jpeg segment, returning the contents as a byte array.
        /// </summary>
        /// <param name="segmentMarker">the byte identifier for the desired segment</param>
        /// <param name="occurrence">the occurrence of the specified segment within the jpeg file</param>
        /// <returns>the byte array if found, else null</returns>
        /// <exception cref="JpegProcessingException">for any problems processing the Jpeg data</exception>
        public byte[] ReadSegment(byte segmentMarker, int occurrence)
        {
            if (segmentDataMap.Contains(segmentMarker))
            {
                IList segmentList = (IList)segmentDataMap[segmentMarker];
                if (segmentList.Count <= occurrence)
                {
                    return null;
                }
                return (byte[])segmentList[occurrence];
            }
            else
            {
                return null;
            }
        }

        /// <summary>
        /// Gets the number of segment
        /// </summary>
        /// <param name="segmentMarker">the byte identifier for the desired segment</param>
        /// <returns>the number of segment or zero if segment does not exist</returns>
        public int GetSegmentCount(byte segmentMarker)
        {
            IList segmentList =
                (IList)segmentDataMap[segmentMarker];
            if (segmentList == null)
            {
                return 0;
            }
            return segmentList.Count;
        }

        /// <summary>
        /// Reads segments
        /// </summary>
        /// <exception cref="JpegProcessingException">for any problems processing the Jpeg data</exception>
        private void ReadSegments()
        {
            segmentDataMap = new Hashtable();
            BufferedStream inStream = GetJpegInputStream();
            try
            {
                int offset = 0;
                // first two bytes should be jpeg magic number
                if (!IsValidJpegHeaderBytes(inStream))
                {
                    throw new JpegProcessingException("not a jpeg file");
                }
                offset += 2;
                do
                {
                    // next byte is 0xFF
                    byte segmentIdentifier = (byte)(inStream.ReadByte() & 0xFF);
                    if ((segmentIdentifier & 0xFF) != 0xFF)
                    {
                        throw new JpegProcessingException(
                            "expected jpeg segment start identifier 0xFF at offset "
                            + offset
                            + ", not 0x"
                            + (segmentIdentifier & 0xFF).ToString("X"));
                    }
                    offset++;
                    // next byte is <segment-marker>
                    byte thisSegmentMarker = (byte)(inStream.ReadByte() & 0xFF);
                    offset++;
                    // next 2-bytes are <segment-size>: [high-byte] [low-byte]
                    byte[] segmentLengthBytes = new byte[2];
                    inStream.Read(segmentLengthBytes, 0, 2);
                    offset += 2;
                    int segmentLength =
                        ((segmentLengthBytes[0] << 8) & 0xFF00)
                        | (segmentLengthBytes[1] & 0xFF);
                    // segment length includes size bytes, so subtract two
                    segmentLength -= 2;
                    if (segmentLength > (inStream.Length - inStream.Position))
                    {
                        throw new JpegProcessingException("segment size would extend beyond file stream length");
                    }
                    byte[] segmentBytes = new byte[segmentLength];
                    inStream.Read(segmentBytes, 0, segmentLength);
                    offset += segmentLength;
                    if ((thisSegmentMarker & 0xFF) == (SEGMENT_SOS & 0xFF))
                    {
                        // The 'Start-Of-Scan' segment's length doesn't include the image data, instead would
                        // have to search for the two bytes: 0xFF 0xD9 (EOI).
                        // It comes last so simply return at this point
                        return;
                    }
                    else if ((thisSegmentMarker & 0xFF) == (MARKER_EOI & 0xFF))
                    {
                        // the 'End-Of-Image' segment -- this should never be found in this fashion
                        return;
                    }
                    else
                    {
                        IList segmentList;
                        if (segmentDataMap.Contains(thisSegmentMarker))
                        {
                            segmentList = (IList)segmentDataMap[thisSegmentMarker];
                        }
                        else
                        {
                            segmentList = new ArrayList();
                            segmentDataMap.Add(thisSegmentMarker, segmentList);
                        }
                        segmentList.Add(segmentBytes);
                    }
                    // didn't find the one we're looking for, loop through to the next segment
                } while (true);
            }
            catch (IOException ioe)
            {
                //throw new JpegProcessingException("IOException processing Jpeg file", ioe);
                throw new JpegProcessingException(
                    "IOException processing Jpeg file: " + ioe.Message,
                    ioe);
            }
            finally
            {
                try
                {
                    if (inStream != null)
                    {
                        inStream.Close();
                    }
                }
                catch (IOException ioe)
                {
                    //throw new JpegProcessingException("IOException processing Jpeg file", ioe);
                    throw new JpegProcessingException(
                        "IOException processing Jpeg file: " + ioe.Message,
                        ioe);
                }
            }
        }

        /// <summary>
        /// Private helper method to create a BufferedInputStream of Jpeg data
        /// from whichever data source was specified upon construction of this instance.
        /// </summary>
        /// <returns>a a BufferedStream of Jpeg data</returns>
        /// <exception cref="JpegProcessingException">for any problems processing the Jpeg data</exception>
        private BufferedStream GetJpegInputStream()
        {
            if (stream != null)
            {
                if (stream is BufferedStream)
                {
                    return (BufferedStream)stream;
                }
                else
                {
                    return new BufferedStream(stream);
                }
            }
            Stream inputStream = null;
            if (data == null)
            {
                try
                {
                    // Added read only access for ASPX use, thanks for Ryan Patridge
                    inputStream = file.Open(FileMode.Open, FileAccess.Read, FileShare.Read);
                }
                catch (FileNotFoundException e)
                {
                    throw new JpegProcessingException(
                        "Jpeg file \"" + file.FullName + "\" does not exist",
                        e);
                }
            }
            else
            {
                inputStream = new MemoryStream(data);
            }
            return new BufferedStream(inputStream);
        }

        /// <summary>
        /// Helper method that validates the Jpeg file's magic number.
        /// </summary>
        /// <param name="fileStream">the InputStream to read bytes from, which must be positioned at its start (i.e. no bytes read yet)</param>
        /// <returns>true if the magic number is Jpeg (0xFFD8)</returns>
        /// <exception cref="JpegProcessingException">for any problems processing the Jpeg data</exception>
        private bool IsValidJpegHeaderBytes(BufferedStream fileStream)
        {
            byte[] header = new byte[2];
            fileStream.Read(header, 0, 2);
            return ((header[0] & 0xFF) == 0xFF && (header[1] & 0xFF) == 0xD8);
        }
    }

    /// <summary>
    /// Represents a JpegProcessing exception
    /// </summary>
    public class JpegProcessingException : CompoundException
    {
        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="message">The error message</param>
        public JpegProcessingException(string message)
            : base(message)
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="message">The error message</param>
        /// <param name="cause">The cause of the exception</param>
        public JpegProcessingException(string message, Exception cause)
            : base(message, cause)
        {
        }

        /// <summary>
        /// Constructor of the object
        /// </summary>
        /// <param name="cause">The cause of the exception</param>
        public JpegProcessingException(Exception cause)
            : base(cause)
        {
        }
    }
}
#endregion
// -->