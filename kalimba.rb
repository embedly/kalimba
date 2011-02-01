require 'camping'
require 'embedly'
require 'open-uri'
require 'hpricot'
require 'json'
require 'digest/sha1'
require 'ostruct'
require 'sass'

# PUNK
class OpenStruct
  def type
    method_missing :type
  end
end

Camping.goes :Kalimba

TAGLINE = "Embedly Colored Glasses for Hacker News"
TOP_COMMENT = true
EMBEDLY_KEY = '409326e2259411e088ae4040f9f86dcd'
IMAGE_ROOT = 'http://static.embed.ly/images/kalimba'
HN_ROOT = 'http://news.ycombinator.com'
GOOGLE_API = 'http://ajax.googleapis.com/ajax/libs'
RATE_LIMIT = 60 # seconds between updates

#module Kalimba
#  include Camping::Session
#end

module Kalimba::Models
  class Article < Base
    def self.normalize_url link
      if link !~ /^http/
        "http://news.ycombinator.com/#{link}"
      else
        link
      end
    end

    def author_link
      Article.normalize_url("user?id=#{self.author}")
    end
  end

  class Update < Base; end

  class Preview < Base

    def self._key url
      Digest::SHA1.hexdigest(url)
    end

    def self.key_exists? url
      find_redirect(url) or find_preview(url)
    end

    def self.find_redirect url
      key = "r::#{_key url}"
      find(:first, :conditions => {:key => key})
    end

    def self.find_preview url
      key = "p::#{_key url}"
      prev = find(:first, :conditions => {:key => key})
      return prev if prev
      if redirect = find_redirect(url)
        return find_preview(redirect.value)
      else
        nil
      end
    end

    def self.save_preview requested_url, preview
      if preview.url != requested_url
        key = "r::#{_key requested_url}"
        # does the redirect exist?
        r = find(:first, :conditions => { :key => key })
        # it does, so update if needed
        if r and r.value != preview.url
          r.value = preview.url
          r.save
        # nope, let's created it
        else
          create :key => key, :value => preview.url
        end
      end

      key = "p::#{_key preview.url}"
      create :key => key, :value => preview.marshal_dump.to_json
    end
  end

  class CreateTables < V 0.1
    def self.up
      create_table Article.table_name do |t|
        t.integer :rank
        t.string :title
        t.string :link
        t.string :comments
      end

      create_table Preview.table_name do |t|
        t.string :key
        t.text :value
        t.timestamps
      end
    end

    def self.down
      drop_table Article.table_name
      drop_table Preview.table_name
    end
  end

  class AddMeta < V 0.2
    def self.up
      change_table Article.table_name do |t|
        t.integer :comment_count
        t.string :author
        t.integer :points
      end
    end

    def self.down
      remove_column Article.table_name, :comment_count
      remove_column Article.table_name, :author
      remove_column Article.table_name, :points
    end
  end

  class AddTopComment < V 0.3
    def self.up
      change_table Article.table_name do |t|
        t.text :top_comment_content
        t.string :top_comment_author
        t.integer :top_comment_points
      end
    end

    def self.down
      remove_column Article.table_name, :top_comment_content
      remove_column Article.table_name, :top_comment_author
      remove_column Article.table_name, :top_comment_points
    end
  end

  class AddRateLimit < V 0.4
    def self.up
      create_table Update.table_name do |t|
        t.string :caller
        t.timestamps
      end
    end

    def self.down
      drop_table Update.table_name
    end
  end
end

module Kalimba::Controllers
  class Index
    def get
      @articles = []
      Article::find(:all, :order => 'id').each do |a|
        preview_row = Preview.find_preview(Article.normalize_url(a.link))
        preview = OpenStruct.new(JSON.parse(preview_row.value)) if preview_row
        @articles << [a, preview]
      end

      render :list_articles
    end
  end

  class Update < R '/update'
    def get

      last_update = Kalimba::Models::Update.find(:last)
      if RATE_LIMIT and last_update and
          last_update.created_at + RATE_LIMIT.seconds > Time.now
        puts 'rate limited'
        redirect R(Index)
        return
      end

      articles = []
      doc = Hpricot(open(HN_ROOT))
      (doc/'.subtext/..').each do |subtext|
        article = subtext.previous_node
        articles << {
          :rank => article.at('.title').inner_html.strip,
          :title => article.at('.title/a').inner_html.strip,
          :link => article.at('.title/a')[:href],
          :comments => Article.normalize_url(subtext.at('a:last')[:href]),
          :comment_count => subtext.at('a:last').inner_html[/\d+/].to_i,
          :author => subtext.at('a').inner_html.strip,
          :points => subtext.at('span').inner_html[/\d+/].to_i
        }
      end

      if TOP_COMMENT
        articles.each do |a|
          begin
            doc = Hpricot(open(a[:comments]))
            top_comment = doc.at('.default')
            if top_comment
              a[:top_comment_points] = top_comment.at('.comhead/span').inner_html[/\d+/]
              a[:top_comment_author] = top_comment.at('.comhead/a').inner_html.strip
              content = []
              node = top_comment.at('.comment')
              # we are intentionally skipping the last node (reply node)
              while node.next_node
                content << node.to_s
                node = node.next_node
              end
              a[:top_comment_content] = content.join
            end
          rescue
            puts "Failed to parse #{a[:comments]}"
          end
        end
      end

      urls = articles.collect {|a| Article.normalize_url(a[:link])}.reject {|a| Preview.key_exists? a}
      if urls.size > 0
        api = ::Embedly::API.new :key => EMBEDLY_KEY
        api.preview(:urls => urls, :maxwidth => 200).each_with_index do |preview, i|
          Preview.save_preview urls[i], preview
        end
      end

      Article.delete_all
      Article.create articles
      Kalimba::Models::Update.create :caller => @request.env['REMOTE_ADDR']

      redirect R(Index)
    end
  end

  # dummies to make links
  class Image < R "#{IMAGE_ROOT}/(.*)"; end
  class HackerNews < R "#{HN_ROOT}/(.*)"; end
  class GoogleApi < R "#{GOOGLE_API}/(.*)"; end
end

module Kalimba::Views
  def layout
    html do
      head do
        title { "Kalimba - #{TAGLINE}" }
        link :href => '/static/css/reset.css', :type => 'text/css', :rel => 'stylesheet'
        link :href => '/static/css/main.css', :type => 'text/css', :rel => 'stylesheet'
        link :rel => 'canonical', :href => 'http://hn.embed.ly'
        link :rel => 'icon', :href => R(Image, 'favicon.ico'), :type => 'image/x-icon'
        link :rel => 'image_src', :href => 'http://static.embed.ly/images/logos/embedly-powered-large-light.png'
        meta :name => 'description', :content => TAGLINE
        meta :name => 'author', :content => 'Embed.ly, Inc.'
        meta :name => 'keywords', :content => 'Hacker News, embedly, embed, news, hacker, ycombinator'
        script(:src => R(GoogleApi, 'jquery/1.4.4/jquery.min.js')) {}
        script(:src => R(GoogleApi, 'jqueryui/1.8.9/jquery-ui.min.js')) {}
        script(:src => 'http://www.shareaholic.com/media/js/jquery.shareaholic-publishers-api.min.js') {}
        script do
          self <<<<-"END"
            jQuery(document).ready(function($) {
              try {
                SHR4P_init();
                $('.shr').shareaholic_publishers({
                  mode: 'inject',
                  service: '202,7,5,40,2,52,3',
                  apikey: '125a4396e029dfd0ff073b5b3d2b4ca66',
                  link: "http://hn.embed.ly",
                  short_link: 'http://bit.ly/ecDrFU',
                  title: 'Kalimba - #{TAGLINE}',
                  center: true
                });
              } catch (e) {}

              $('.top_comment_link').click(function(event) {
                event.preventDefault();
                $(this).parent().find('.top_comment').toggle('fast');
              });

              var index = -1; // so first is 1

              var current = function() {
                return $('a[name='+(index+1)+']').parent();
              }
              var up = function() {
                if (index > 0) {
                  index--;
                  index %= 30;
                  document.location.href = '#'+(index+1);
                  highlight();
                }
              }
              var down = function() {
                if (index < 29) {
                  index++;
                  index %= 30;
                  document.location.href = '#'+(index+1);
                  highlight();
                }
              }
              var toggle_content = function() {
                if (index < 30 && index >= 0) {
                  current().find('.embedly_content').toggle('fast')
                }
              }
              var toggle_comments = function() {
                if (index < 30 && index >= 0) {
                  current().find('.top_comment').toggle('fast')
                }
              }
              var follow = function(shift) {
                var href = current().find('.embedly_title').find('a').last().attr('href');
                if (shift) {
                  window.open(href);
                } else {
                  document.location.href = href;
                }
              }
              var highlight = function() {
                $('.article_rank').removeClass('selected');
                if (index < 30 && index >= 0) {
                  current().find('.article_rank').addClass('selected');
                }
              }

              if (document.location.hash) {
                index = document.location.hash.substring(1) - 1;
                highlight();
              }

              $(document).keypress(function(event) {
                switch(event.which) {
                case 106: // j
                  event.preventDefault();
                  down();
                  break;
                case 107: // k
                  event.preventDefault();
                  up();
                  break;
                case 99:  // c
                  event.preventDefault();
                  toggle_comments();
                  break;
                case 100: // d
                  event.preventDefault();
                  toggle_content();
                  break;
                case 13:  // enter
                  event.preventDefault();
                  follow(event.shiftKey);
                default:
                  break;
                }
              });

              // for arrows
              $(document).keyup(function(event) {
                switch(event.keyCode) {
                case 39:  // down arrow
                  event.preventDefault();
                  down();
                  break;
                case 37:  // up arrow
                  event.preventDefault();
                  up();
                default:
                  break;
                }
              });
            });
          END
        end
        script do
          self <<<<-'END'
            var _gaq = _gaq || [];
            _gaq.push(['_setAccount', 'UA-15045445-6']);
            _gaq.push(['_trackPageview']);

            (function() {
              var ga = document.createElement('script'); ga.type = 'text/javascript'; ga.async = true;
              ga.src = ('https:' == document.location.protocol ? 'https://ssl' : 'http://www') + '.google-analytics.com/ga.js';
              var s = document.getElementsByTagName('script')[0]; s.parentNode.insertBefore(ga, s);
            })();
         END
        end
      end

      body do
        div.header do
          div.title "KALIMBA - #{TAGLINE}"
        end
        div.main do
          self << yield
        end
      end
    end
  end

  def list_articles
    ul.article_list do
      @articles.each do |article, preview|
        li.article do
          a.index :name => article.rank {}
          div.article_rank { "#{article.rank}" }
          div.article_content do
            if preview and preview.title and preview.title.strip != ''
              _embed(article, preview)
            else
              div.embedly do
                div.embedly_title do
                  a.article_link article.title, :href => article.link, :target => '_blank'
                end
              end
            end
            div.article_meta do
              self << "#{article.points} points by "
              a.author_link article.author,
                :href => article.author_link, :target => '_blank'
              self << " | "
              a.comment_link "#{article.comment_count} comments",
                :href => article.comments, :target => '_blank'
              if TOP_COMMENT
                a.top_comment_link :href => '#', :title => 'see top comment' do
                  self << ' '
                  img.top_comment_icon :src => R(Image, "icon_eye.png"), :alt => 'see top comment'
                end
                div.top_comment do
                  div.comment_head do
                    self << "#{article.top_comment_points} points by "
                    a.top_comment_author article.top_comment_author,
                      :href => R(HackerNews, "user?id=#{article.top_comment_author}")
                  end
                  div.comment_content { article.top_comment_content }
                end
              end
            end
          end
          div.clear {}
        end
      end
    end
    div.like {'<iframe src="http://www.facebook.com/plugins/like.php?href=http%3A%2F%2Fkalimba.embed.ly&amp;layout=button_count&amp;show_faces=true&amp;width=450&amp;action=like&amp;colorscheme=light&amp;height=21" scrolling="no" frameborder="0" style="border:none; overflow:hidden; width:450px; height:21px;" allowTransparency="true"></iframe>'}
    div.clear {}
    div.shr {}
    div.clear {}
    div.footer do
      a 'About', :href => 'http://news.ycombinator.com/item?id=2152950'
      self << ' | '
      a 'Hacker News', :href => 'http://news.ycombinator.com'
      self << ' | '
      a 'Embedly', :href => 'http://embed.ly'
      self << ' | '
      a 'Feedback', :href => 'mailto:bob@embed.ly'
      self << ' | '
      a '@doki_pen', :href => 'http://twitter.com/doki_pen'
    end
  end

  # Too complicated
  def _content article, preview
    case preview.type
    when 'image'
      a.embedly_thumbnail(:href => preview.original_url) do
        img.thumbnail :src => preview.url
      end
    when 'video'
      video.embedly_video :src => preview.url, :controls => "controls", :preload => "preload"
    when 'audio'
      audio.embedly_video :src => preview.url, :controls => "controls", :preload => "preload"
    else
      if preview.content
        div.embedly_title do
          a article.title, :target => '_blank', :href => preview.url
        end
        div.embedly_content do
          p { preview.content }
        end
      else
        case preview.object['type']
        when 'photo'
          div.embedly_content do
            a.embedly_thumbnail :href => preview.original_url do
              img.thumbnail :src => preview.object_url
            end
          end
        when 'video', 'rich'
          div.embedly_content { preview.object['html'] }
        else
          div.embedly_title do
            a article.title, :target => '_blank', :href => preview.original_url, :title => preview.url
          end

          div.embedly_content do
            if preview.images.length != 0
              a.embedly_thumbnail_small :target => '_blank', :href => preview.original_url, :title => preview.url do
                img.thumbnail :src => preview.images.first['url']
              end
            end

            p { preview.description }

            div { preview.embeds.first['html'] if preview.embeds.length > 0 }
          end
        end
      end
    end
    div.clear {}
    div.provider do
      self << 'via '
      if preview.favicon_url
        img.provider_favicon :src => preview.favicon_url
        self << ' '
      end
      a.provider_link preview.provider_name, :href => preview.provider_url
    end
  end

  def _embed article, preview
    div.embedly { _content article, preview }
  end
end

def Kalimba.create
  #Camping::Models::Session.create_schema
  Kalimba::Models.create_schema
end
