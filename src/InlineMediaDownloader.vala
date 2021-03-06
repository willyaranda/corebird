/*  This file is part of corebird, a Gtk+ linux Twitter client.
 *  Copyright (C) 2013 Timm Bäder
 *
 *  corebird is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  corebird is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with corebird.  If not, see <http://www.gnu.org/licenses/>.
 */


namespace InlineMediaDownloader {
  const int THUMB_SIZE = 40;
  private Soup.Session session;

  async void try_load_media(Tweet t, string url) {
    if(!Settings.show_inline_media())
      return;

    if (session == null)
      session = new Soup.Session ();
    /*
        TODO: Support For:
        * yfrog
        * lockerz.com
        * say.ly
          * <img src="contentImage" src="(.*?)"
        * moby.tv

        * Youtube (Preview image with video indicator. Click on the video
                   opens/streams it in some video player)
        * vine! (thumbnails supported)

    */

    if(url.has_prefix("http://instagr.am") ||
       url.has_prefix("http://instagram.com/p/")) {
      two_step_load.begin(t, url, "<meta property=\"og:image\" content=\"(.*?)\"", 1);
    } else if (url.has_prefix("http://i.imgur.com")) {
      load_inline_media.begin(t, url);
    } else if (url.has_prefix("http://d.pr/i/") || url.has_prefix("http://ow.ly/i/") ||
               url.has_prefix("https://vine.co/v/") || url.has_prefix("http://tmblr.co/")) {
      two_step_load.begin(t, url, "<meta property=\"og:image\" content=\"(.*?)\"",
                          1);
    } else if (url.has_prefix("http://pbs.twimg.com/media/")) {
      load_inline_media.begin(t, url);
    } else if (url.has_prefix("http://twitpic.com/")) {
      two_step_load.begin(t, url,
                          "<meta name=\"twitter:image\" value=\"(.*?)\"", 1);
    }
  }

  private async void two_step_load(Tweet t, string first_url, string regex_str,
                                          int match_index) {
    var msg     = new Soup.Message("GET", first_url);
    session.queue_message(msg, (_s, _msg) => {
    string back = (string)_msg.response_body.data;
      try{
        var regex = new GLib.Regex(regex_str, 0);
        MatchInfo info;
        regex.match(back, 0, out info);
        string real_url = info.fetch(match_index);
        if(real_url != null)
          load_inline_media.begin(t, real_url);
      } catch (GLib.RegexError e) {
        critical("Regex Error(%s): %s", regex_str, e.message);
      }
    });

  }

  private async void load_inline_media(Tweet t, string url) { //{{{

    // First, check if the media already exists...
    string path = get_media_path (t, url);
    string thumb_path = get_thumb_path (t, url);
    if(FileUtils.test(path, FileTest.EXISTS)) {
      /* If the media already exists, the thumbnail also exists.
         If not, fuck you.*/
      try {
        var thumb = new Gdk.Pixbuf.from_file(thumb_path);
        fire_media_added(t, path, thumb, thumb_path);
        return;
      } catch (GLib.Error e) {
        critical (e.message);
      }
    }


    debug("Directly Downloading %s", url);
    var msg = new Soup.Message("GET", url);
    msg.got_headers.connect (() => {
      int64 content_length = msg.response_headers.get_content_length ();
      double mb = content_length / 1024.0 / 1024.0;
      double max = Settings.max_media_size ();
      if (mb > max) {
        message ("Image %s won't be downloaded,  %fMB > %fMB", url, mb, max);
        session.cancel_message (msg, Soup.Status.CANCELLED);
      }
    });

    session.queue_message(msg, (s, _msg) => {
      if (_msg.status_code == Soup.Status.CANCELLED)
        return;

      try {
        var ms  = new MemoryInputStream.from_data(_msg.response_body.data, null);
        string ext = Utils.get_file_type(url);
        if(ext.length == 0)
          ext = "png";
        ext = ext.down();

        int qm_index;
        if ((qm_index = ext.index_of_char ('?')) != -1) {
          ext = ext.substring (0, qm_index);
        }

        if (ext == "jpg")
          ext = "jpeg";

        var media_out_stream = File.new_for_path (path).create (FileCreateFlags.REPLACE_DESTINATION);
        var thumb_out_stream = File.new_for_path (thumb_path).create (FileCreateFlags.REPLACE_DESTINATION);

        media_out_stream.write_all (_msg.response_body.data, null, null);
        if(ext == "gif"){
          load_animation (t, ms, media_out_stream, thumb_out_stream, path, thumb_path);
        } else {
          load_normal_media (t, ms, media_out_stream, thumb_out_stream, path, thumb_path);
        }
      } catch (GLib.Error e) {
        critical (e.message + " for MEDIA " + url);
      }
    });
  } //}}}

  private void load_animation (Tweet t,
                               MemoryInputStream in_stream,
                               OutputStream out_stream,
                               OutputStream thumb_out_stream,
                               string path, string thumb_path) {
    pixbuf_animation_from_stream_async.begin (in_stream, null, (obj, res) => {
      Gdk.PixbufAnimation anim = null;
      try {
        anim = pixbuf_animation_from_stream_async.end (res);
      } catch (GLib.Error e) {
        warning (e.message);
        return;
      }
      var pic = anim.get_static_image();
      var thumb = slice_pixbuf (pic);
      thumb.save_to_stream_async.begin (thumb_out_stream, "png", null, () => {
        fire_media_added(t, path, thumb, thumb_path);
      });
    });
  }

  private void load_normal_media (Tweet t,
                                  MemoryInputStream in_stream,
                                  OutputStream out_stream,
                                  OutputStream thumb_out_stream,
                                  string path, string thumb_path) {
    pixbuf_from_stream_async.begin (in_stream, null, (obj, res) => {
      Gdk.Pixbuf pic = null;
      try {
        pic = pixbuf_from_stream_async.end (res);
      } catch (GLib.Error e) {
        warning ("%s(%s)", e.message, path);
        return;
      }
      var thumb = slice_pixbuf (pic);
      thumb.save_to_stream_async.begin (thumb_out_stream, "png", null, () => {
        fire_media_added(t, path, thumb, thumb_path);
      });
    });
  }

  /**
   * Slices the given pixbuf to a smaller thumbnail image.
   *
   * @param pic The Gdk.Pixbuf to use as base image
   *
   * @return The created thumbnail
   */
  private Gdk.Pixbuf slice_pixbuf (Gdk.Pixbuf pic) {
    int x, y, w, h;
    calc_thumb_rect (pic.get_width (), pic.get_height (), out x, out y, out w, out h);
    var big_thumb = new Gdk.Pixbuf (Gdk.Colorspace.RGB, true, 8, w, h);
    pic.copy_area (x, y, w, h, big_thumb, 0, 0);
    var thumb = big_thumb.scale_simple (THUMB_SIZE, THUMB_SIZE, Gdk.InterpType.TILES);
    return thumb;
  }


  private void fire_media_added(Tweet t, string path, Gdk.Pixbuf thumb,
                                string thumb_path) {
    t.media = path;
    t.media_thumb = thumb_path;
    t.inline_media = thumb;
    t.inline_media_added(thumb);
  }

  private string get_media_path (Tweet t, string url) {
    string ext = Utils.get_file_type (url);
    ext = ext.down();
    if(ext.length == 0)
      ext = "png";

    return Dirs.cache (@"assets/media/$(t.id)_$(t.user_id).$(ext)");
  }

  private string get_thumb_path (Tweet t, string url) {
    return Dirs.cache (@"assets/media/thumbs/$(t.id)_$(t.user_id).png");
  }

  /**
   * Calculates the region of the image the thumbnail should be composed of.
   *
   * @param img_width  The width of the original image
   * @param img_height The height of the original image
   *
   */
  private void calc_thumb_rect (int img_width, int img_height,
                                out int x, out int y, out int width, out int height) {
    float ratio = img_width / (float)img_height;
    if (ratio >= 0.9 && ratio <= 1.1) {
      // it's more or less squared, so...
      x = y = 0;
      width = img_width;
      height = img_height;
    } else if (ratio > 1.1) {
      // The image is pretty wide but not really high
      x = (img_width/2) - (img_height/2);
      y = 0;
      width = height = img_height;
    } else {
      x = 0;
      y = (img_height/2) - (img_width/2);
      width = height = img_width;
    }
  }
}
