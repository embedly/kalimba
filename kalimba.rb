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
end

module Kalimba::Controllers
  class Index < R '/'
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
      Article.delete_all

      articles = []
      doc = Hpricot(open('http://news.ycombinator.com/'))
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


      urls = articles.collect {|a| Article.normalize_url(a[:link])}.reject {|a| Preview.key_exists? a}
      if urls.size > 0
        api = ::Embedly::API.new :key => '409326e2259411e088ae4040f9f86dcd'
        api.preview(:urls => urls, :maxwidth => 200).each_with_index do |preview, i|
          Preview.save_preview urls[i], preview
        end
      end

      Article.create articles


      redirect R(Index)
    end
  end
end

module Kalimba::Views
  def layout
    html do
      head do
        title { "Kalimba - #{TAGLINE}" }
        link :href => '/static/css/reset.css', :type => 'text/css', :rel => 'stylesheet'
        link :href => '/static/css/main.css', :type => 'text/css', :rel => 'stylesheet'
        link :rel => 'canonical', :href => 'http://kalimba.embed.ly/'
        link :rel => 'icon', :href => 'http://static.embed.ly/images/kalimba/favicon.ico', :type => 'image/x-icon'
        link :rel => 'image_src', :href => 'http://static.embed.ly/images/logos/embedly-powered-large-light.png'
        meta :name => 'description', :content => TAGLINE
        meta :name => 'author', :content => 'Embed.ly, Inc.'
        meta :name => 'keywords', :content => 'Hacker News, embedly, embed, news, hacker, ycombinator'
        script(:src => 'http://ajax.googleapis.com/ajax/libs/jquery/1.4.2/jquery.min.js') {}
        script(:src => 'http://www.shareaholic.com/media/js/jquery.shareaholic-publishers-api.min.js') {}
        script do
          self <<<<-"END"
            jQuery(document).ready(function($) {
              SHR4P_init();
              $('.shr').shareaholic_publishers({
                mode: 'inject',
                service: '202,7,5,40,2,52,3',
                apikey: '125a4396e029dfd0ff073b5b3d2b4ca66',
                link: 'http://kalimba.embed.ly',
                short_link: 'http://bit.ly/ecDrFU',
                title: 'Kalimba - #{TAGLINE}',
                center: true
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
          div.article_rank { "#{article.rank}" }
          div.article_content do
            if preview and preview.title and preview.title.strip != ''
              _embed(preview)
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
            end
          end
          div.clear {}
        end
      end
    end
    div.like {'<iframe src="http://www.facebook.com/plugins/like.php?href=http%3A%2F%2Fkalimba.embed.ly&amp;layout=button_count&amp;show_faces=true&amp;width=450&amp;action=like&amp;colorscheme=light&amp;height=21" scrolling="no" frameborder="0" style="border:none; overflow:hidden; width:450px; height:21px;" allowTransparency="true"></iframe>'}
    div.clear {}
    div.shr {}
  end

  # Too complicated
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
        div.embedly_title do
          a preview.title, :target => '_blank', :href => preview.url
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
            a preview.title, :target => '_blank', :href => preview.original_url, :title => preview.url
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
  end

  def _embed preview
    div.embedly { _content preview }
  end
end

def Kalimba.create
  #Camping::Models::Session.create_schema
  Kalimba::Models.create_schema
end
