%w{camping embedly open-uri hpricot json digest/sha1 ostruct sass yaml builder}.each {|r| require r}

# PUNK
class OpenStruct
  def type
    method_missing :type
  end
end

Camping.goes :Kalimba

CONFIG = YAML.load(File.read('config/app.yml'))

module Kalimba::Models
  class Article < Base
    def self.normalize_url link
      if link !~ /^http/
        "#{CONFIG[:hn_root]}/#{link}"
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

  class Update
    def get
      last_update = Kalimba::Models::Update.find(:last)
      if CONFIG[:rate_limit] and last_update and
          last_update.created_at + CONFIG[:rate_limit].seconds > Time.now
        redirect R(Index)
        return
      end

      articles = []
      doc = Hpricot(open(CONFIG[:hn_root]))
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

      if CONFIG[:top_comment]
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
        api = ::Embedly::API.new :key => CONFIG[:embedly_key], :user_agent => 'Mozilla/5.0 (compatible; Kalimba/0.1;)'
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

  class Rss < R "/atom.xml"
    def get
      last_update = Kalimba::Models::Update.find(:last)
      if last_update
        @headers['Content-Type'] = 'text/xml; charset=utf-8'
        b = ::Builder::XmlMarkup.new :indent => 2
        b.instruct!
        b.rss(
            'xmlns' => 'http://www.w3.org/2005/Atom',
            'xmlns:content' => 'http://purl.org/rss/1.0/modules/content/',
            'version' => '2.0') do |r|
          r.channel do |c|
            c.title 'Kalimba'
            c.link :href => CONFIG[:canonical_url]
            c.id CONFIG[:canonical_url]
            c.link :rel => 'self', :type => 'application/rss+xml', :href=> "#{CONFIG[:canonical_url]}#{R(Rss)}"
            c.description CONFIG[:tagline]
            c.updated last_update.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
            c.author do |a|
              a.name CONFIG[:author_name]
              a.email CONFIG[:author_email]
              a.email CONFIG[:author_uri]
            end
            c.generator 'Kalimba'
          end
          Article::find(:all, :order => 'id').each do |a|
            preview_row = Preview.find_preview(Article.normalize_url(a.link))
            preview = OpenStruct.new(JSON.parse(preview_row.value)) if preview_row
            r.item do |i|
              i.title a.title
              i.link a.link, :rel => 'alternative', :type => 'text/html'
              i.comments a.comments
              i.id a.link
              if preview_row
                i.updated preview_row.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
                i.published preview_row.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
              else
                i.updated last_update.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
                i.published last_update.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
              end
              i.author do |author|
                author.name a.author
                author.uri a.author_link
              end
              content = render(:_content, preview) if preview
              if content
                i.content do |c|
                  c.cdata! content
                end
              end
              i.description preview.description if preview
              i.summary preview.description if preview
            end
          end
        end
      end
    end
  end

  # dummies to make links
  class Image < R "#{CONFIG[:image_root]}/(.*)"; end
  class HackerNews < R "#{CONFIG[:hn_root]}/(.*)"; end
  class GoogleApi < R "#{CONFIG[:google_api]}/(.*)"; end
end

module Kalimba::Views
  def layout
    html do
      head do
        title { "Kalimba - #{CONFIG[:tagline]}" }
        link :href => '/static/css/reset.css', :type => 'text/css', :rel => 'stylesheet'
        link :href => '/static/css/main.css', :type => 'text/css', :rel => 'stylesheet'
        link :rel => 'canonical', :href => CONFIG[:canonical_url]
        link :rel => 'icon', :href => R(Image, 'favicon.ico'), :type => 'image/x-icon'
        link :rel => 'image_src', :href => 'http://static.embed.ly/images/logos/embedly-powered-large-light.png'
        link :rel => 'alternative', :type => 'application/rss+xml', :title => 'Kalimba RSS Feed', :href => R(Rss)
        meta :name => 'description', :content => CONFIG[:tagline]
        meta :name => 'author', :content => 'Embed.ly, Inc.'
        meta :name => 'keywords', :content => 'Hacker News, embedly, embed, news, hacker, ycombinator'
        script(:src => R(GoogleApi, 'jquery/1.4.4/jquery.min.js')) {}
        script(:src => R(GoogleApi, 'jqueryui/1.8.9/jquery-ui.min.js')) {}

        if CONFIG[:shareaholic_key]
          script do
            self <<<<-"END"
              jQuery(document).ready(function($) {
                if (typeof(SHR4P) == 'undefined') {
                  SHR4P = {};
                }
                SHR4P.onready = function() {
                  SHR4P.jQuery('.shr').shareaholic_publishers({
                    mode: 'inject',
                    showShareCount: true,
                    service: '202,7,5,40,2,52,3',
                    apikey: '#{CONFIG[:shareaholic_key]}',
                    link: "#{CONFIG[:canonical_url]}",
                    short_link: '#{CONFIG[:short_url]}',
                    title: 'Kalimba - #{CONFIG[:tagline]}',
                    center: true
                  });
                };
                if (typeof(SHR4P.ready) != 'undefined' && SHR4P.ready) {
                  SHR4P.onready();
                }
              });
            END
          end
          script(:src => CONFIG[:shareaholic_plugin]) {}
        end

        script do
          self <<<<-"END"
            jQuery(document).ready(function($) {
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
        if CONFIG[:google_analytics_key]
          script do
            self <<<<-"END"
              var _gaq = _gaq || [];
              _gaq.push(['_setAccount', '#{CONFIG[:google_analytics_key]}']);
              _gaq.push(['_trackPageview']);

              (function() {
                var ga = document.createElement('script'); ga.type = 'text/javascript'; ga.async = true;
                ga.src = ('https:' == document.location.protocol ? 'https://ssl' : 'http://www') + '.google-analytics.com/ga.js';
                var s = document.getElementsByTagName('script')[0]; s.parentNode.insertBefore(ga, s);
              })();
           END
          end
        end
      end

      body do
        div.header do
          div.title "KALIMBA - #{CONFIG[:tagline]}"
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
              if CONFIG[:tagline] and article.comment_count and article.comment_count > 0
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
    div.like {CONFIG[:fblike_fragment]}
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
      a 'Feedback', :href => "mailto:#{CONFIG[:author_email]}"
      self << ' | '
      a '@doki_pen', :href => 'http://twitter.com/doki_pen'
    end
  end

  def _content preview
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
    div.embedly do
      div.embedly_title do
        a article.title, :target => '_blank', :href => preview.original_url, :title => preview.url
      end
      _content preview
    end
  end
end

def Kalimba.create
  Kalimba::Models.create_schema
end
