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
          :rank => article.at('.title').inner_html,
          :title => article.at('.title/a').inner_html,
          :link => article.at('.title/a')[:href],
          :comments => Article.normalize_url(subtext.at('a:last')[:href])
        }
      end


      urls = articles.collect {|a| Article.normalize_url(a[:link])}.reject {|a| Preview.key_exists? a}
      if urls.size > 0
        api = ::Embedly::API.new :key => '409326e2259411e088ae4040f9f86dcd'
        api.preview(:urls => urls).each_with_index do |preview, i|
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
        title { "Kalimba - Rose Colored Glasses for Hacker News" }
        link :href => '/static/css/reset.css', :type => 'text/css', :rel => 'stylesheet'
        link :href => '/static/css/main.css', :type => 'text/css', :rel => 'stylesheet'
        script(:src => 'http://ajax.googleapis.com/ajax/libs/jquery/1.4.2/jquery.min.js') {}
        script do
          self <<<<-'SCRIPT'
          jQuery(document).ready(function($) {
            $('.embedly_toggle').each(function() {
              var self = $(this);
              self.find('.toggle_button').click(function() {
                self.find('.embedly').toggle('fast');
                return false;
              });
            });
          });
          SCRIPT
        end
      end

      body do
        div.main { self << yield }
      end
    end
  end

  def list_articles
    ul.article_list do
      @articles.each do |article, preview|
        li.article do
          span.article_rank "#{article.rank}. "
          a.article_link article.title, :href => article.link, :target => '_blank'
          br
          a.comment_link 'Comments', :href => article.comments, :target => '_blank'
          div do
    #        h1 'preview'
    #        pre(JSON.pretty_generate(preview.marshal_dump))
            _embed(preview) if preview
          end
        end
      end
    end
  end

  # Too complicated
  def _content preview
    case preview.type
    when 'image'
      a.embedly_thumbnail(:href => preview.original_url) do
        img :src => preview.url
      end
    when 'video'
      video.embedly_video :src => preview.url, :controls => "controls", :preload => "preload"
    when 'audio'
      audio.embedly_video :src => preview.url, :controls => "controls", :preload => "preload"
    else
      if preview.content
        span.embedly_title do
          a preview.title, :target => '_blank', :href => preview.url
        end
        p { preview.content }
      else
        case preview.object['type']
        when 'photo'
          a.embedly_thumbnail :href => preview.original_url do
            img :src => preview.object_url
          end
        when 'video', 'rich'
          div { preview.object['html'] }
        else
          if preview.type == 'html'
            a.embedly_title preview.title, :target => '_blank', :href => preview.original_url, :title => preview.url
            div.clear

            if preview.images.length != 0
              if preview.images.first['width'] >= 450
                a.embedly_thumbnail :target => '_blank', :href => preview.original_url, :title => preview.url do
                  img :src => preview.images.first['url']
                end
              else
                a.embedly_thumbnail_small :target => '_blank', :href => preview.original_url, :title => preview.url do
                  img :src => preview.images.first['url']
                end
              end
            end

            p preview.description

            div.clear
            div { preview.embeds.first['html'] if preview.embeds.length > 0 }
          end
        end
      end
    end
  end

  def _embed preview
    div.embedly_toggle do
      a.toggle_button 'click me', :href => '#'
      div.embedly { _content preview }
      div.clear
    end
  end
end

def Kalimba.create
  #Camping::Models::Session.create_schema
  Kalimba::Models.create_schema
end
