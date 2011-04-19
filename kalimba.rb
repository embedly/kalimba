%w{camping embedly open-uri nokogiri json digest/sha1 ostruct sass yaml builder}.each {|r| require r}

Camping.goes :Kalimba

CONFIG = YAML.load(File.read('config/app.yml'))

module Kalimba
  def r404 path
    @code = 404
    @message = "Page Not Found"
    render :error
  end
  def r500 klass, method, exception
    puts exception.inspect
    puts exception.backtrace
    @code = 500
    @message = "An Unexpected Error Has Occurred"
    render :error
  end
  def r501 method
    @code = 501
    @message = "#{method.capitalize} Isn't Supported"
    render :error
  end
end

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

  class RemoveTopCommentPoints < V 0.5
    def self.up
      remove_column Article.table_name, :top_comment_points
    end

    def self.down
      change_table Article.table_name do |t|
        t.integer :top_comment_points
      end
    end
  end

  class WidenTopCommentAuthor < V 0.6
    def self.up
      change_column Article.table_name, "top_comment_author", :text
    end

    def self.down
      change_column Article.table_name, "top_comment_author", :string
    end
  end

  class WidenLink < V 0.7
    def self.up
      change_column Article.table_name, "link", :text
    end

    def self.down
      change_column Article.table_name, "link", :string
    end
  end
end

module Kalimba::Controllers
  class Index
    def get
      raise 'Failure' if @input.fail # for testing
      @shortcuts_on = true
      @articles = []
      Article::find(:all, :order => 'id').each do |a|
        preview_row = Preview.find_preview(Article.normalize_url(a.link))
        preview = ::Embedly::EmbedlyObject.new(JSON.parse(preview_row.value)) if preview_row
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

      # clean cache
      Preview.where("created_at < :expiration", 
                    :expiration => Time.now - 2.days).each do |r|
        r.delete
      end

      articles = []
      doc = Nokogiri::HTML(open(CONFIG[:hn_root]))
      doc.css('.subtext').xpath('..').each do |subtext|
        article = subtext.previous
        begin
          articles << {
            :rank => article.at_css('.title').inner_html.strip,
            :title => article.at_css('.title/a').inner_html.strip,
            :link => article.at_css('.title/a')[:href],
            :comments => Article.normalize_url(subtext.at_css('a:last')[:href]),
            :comment_count => subtext.at_css('a:last').inner_html[/\d+/].to_i,
            :author => subtext.at_css('a').inner_html.strip,
            :points => subtext.at_css('span').inner_html[/\d+/].to_i
          }
        rescue
          # TODO something?
          puts "Failed to parse article"
          puts $!.inspect
          puts $!.backtrace
        end
      end

      if CONFIG[:top_comment]
        articles.each do |a|
          begin
            doc = Nokogiri::HTML(open(a[:comments]))
            top_comment = doc.at_css('.default')
            if top_comment
              a[:top_comment_author] = top_comment.at_css('.comhead/a').inner_html.strip
              content = []
              node = top_comment.at_css('.comment')
              # we are intentionally skipping the last node (reply node)
              while node.next
                content << node.to_s
                node = node.next
              end
              a[:top_comment_content] = content.join
            end
          rescue
            # TODO something?
            puts "Failed to parse #{a[:comments]}"
            puts $!.inspect
            puts $!.backtrace
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

  class KeysJs < R "/media/js/keys.js"
    def get
      @headers['Content-Type'] = 'text/javascript'
      render :_keys_js
    end
  end

  class ShareaholicJs < R "/media/js/shareaholic.js"
    def get
      @headers['Content-Type'] = 'text/javascript'
      render :_shareaholic_js
    end
  end

  class AnalyticsJs < R "/media/js/analytics.js"
    def get
      @headers['Content-Type'] = 'text/javascript'
      render :_analytics_js
    end
  end

  class Rss < R "/atom.xml"
    def get
      @last_update = Kalimba::Models::Update.find(:last)
      return unless @last_update

      @articles = []
      Article::find(:all, :order => 'id').each do |a|
        preview_row = Preview.find_preview(Article.normalize_url(a.link))
        preview = OpenStruct.new(JSON.parse(preview_row.value)) if preview_row
        @articles << [a, preview_row, preview]
      end

      @headers['Content-Type'] = 'application/atom+xml; charset=utf-8'
      @b = ::Builder::XmlMarkup.new :indent => 2
      @b.instruct!

      render :_rss
    end
  end

  # dummies to make links
  class Image < R "#{CONFIG[:image_root]}/(.*)"; end
  class Javascript < R "#{CONFIG[:js_root]}/(.*)"; end
  class Css < R "#{CONFIG[:css_root]}/(.*)"; end
  class HackerNews < R "#{CONFIG[:hn_root]}/(.*)"; end
  class GoogleApi < R "#{CONFIG[:google_api]}/(.*)"; end
  class GoogleFonts < R "http://fonts.googleapis.com/css"; end
end

module Kalimba::Views
  def layout
    xhtml_transitional do
      head do
        title { "Kalimba - #{CONFIG[:tagline]}" }
        link :href => '/static/css/reset.css', :type => 'text/css', :rel => 'stylesheet'
        link :href => '/static/css/main.css', :type => 'text/css', :rel => 'stylesheet'
        link :href => R(Css, 'facebox.css'), :type => 'text/css', :rel => 'stylesheet'
        link :href => R(GoogleFonts, :family => 'Tangerine'), :type => 'text/css', :rel => 'stylesheet'
        link :rel => 'canonical', :href => CONFIG[:canonical_url]
        link :rel => 'icon', :href => R(Image, 'favicon.ico'), :type => 'image/x-icon'
        link :rel => 'image_src', :href => 'http://static.embed.ly/images/logos/embedly-powered-large-light.png'
        if CONFIG[:rss]
          link :rel => 'alternative', :type => 'application/rss+xml', :title => 'Kalimba Feedburner RSS Feed', :href => CONFIG[:rss]
        else
          link :rel => 'alternative', :type => 'application/atom+xml', :title => 'Kalimba Atom Feed', :href => R(Rss)
        end
        meta :name => 'description', :content => CONFIG[:tagline]
        meta :name => 'author', :content => 'Embed.ly, Inc.'
        meta :name => 'keywords', :content => 'Hacker News, embedly, embed, news, hacker, ycombinator'
        script(:type => 'text/javascript', :src => R(GoogleApi, 'jquery/1.4.4/jquery.min.js')) {}
        script(:type => 'text/javascript', :src => R(GoogleApi, 'jqueryui/1.8.9/jquery-ui.min.js')) {}
        script(:type => 'text/javascript', :src => R(Javascript, 'facebox.js')) {}
        script(:type => 'text/javascript', :src => R(KeysJs)) {}

        if CONFIG[:shareaholic_key]
          script(:type => 'text/javascript', :src => R(ShareaholicJs)) {}
          script(:type => 'text/javascript', :src => CONFIG[:shareaholic_plugin]) {}
        end

        if CONFIG[:google_analytics_key]
          script(:type => 'text/javascript', :src => R(AnalyticsJs)) {}
        end
      end

      body do
        div.header do
          div.title do
            a.home "KALIMBA - #{CONFIG[:tagline]}", :href => CONFIG[:canonical_url]
            a.rss_link :href => (CONFIG[:rss] or R(Rss)) do
              img.rss :src => R(Image, 'feed-icon32x32.png'), :alt => 'rss'
            end
          end
        end
        div.main do
          self << yield
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
            if @shortcuts_on
              self << ' | '
              a 'Shortcuts', :name => 'keys'
            end
          end
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
                    self << "by "
                    a.top_comment_author article.top_comment_author,
                      :href => R(HackerNews, "user", :id=> article.top_comment_author)
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

    div.shortcuts! do
      h2 'Keyboard Shortcuts'
      hr
      dl.shortcut do
        dt { 'j or &#8594;' }
        dd 'Select next article'
      end
      dl.shortcut do
        dt { 'k or &#8592;' }
        dd 'Select previous article'
      end
      dl.shortcut do
        dt 'c'
        dd 'Toggle Hacker News top comment'
      end
      dl.shortcut do
        dt 'shift + c'
        dd 'Open Hacker News comments page in a new window'
      end
      dl.shortcut do
        dt 'd'
        dd 'Toggle article content'
      end
      dl.shortcut do
        dt 'enter'
        dd 'Follow the article link in this window'
      end
      dl.shortcut do
        dt 'shift + enter'
        dd 'Follow the article link in a new window'
      end
      dl.shortcut do
        dt '?'
        dd 'Show this keyboard shortcuts dialog'
      end
    end
  end

  def _content preview
    begin
      case preview.type
      when 'image'
        a.embedly_thumbnail(:href => preview.original_url) do
          img.thumbnail :src => preview.url, :alt => 'goto article'
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
          case preview.object.type
          when 'photo'
            div.embedly_content do
              a.embedly_thumbnail :href => preview.original_url do
                img.thumbnail :src => preview.object_url, :alt => 'goto article'
              end
            end
          when 'video'
            div.embedly_content { preview.object.html }
          when 'rich'
            div.embedly_content { preview.html }
          else
            div.embedly_content do
              if preview.images.length != 0
                a.embedly_thumbnail_small :target => '_blank', :href => preview.original_url, :title => preview.url do
                  img.thumbnail :src => preview.images.first['url'], :alt => 'thumbnail'
                end
              end

              p { preview.description }

              div { preview.embeds.first['html'] if preview.embeds.length > 0 }
            end
          end
        end
      end
      div.clear {}
      div.provider :style => 'float: right;' do
        self << 'via '
        if preview.favicon_url
          img.provider_favicon :src => preview.favicon_url, :alt => 'favicon'
          self << ' '
        end
        a.provider_link preview.provider_name, :href => preview.provider_url
      end
    rescue
      div.embedly_content { 'ERROR' }
      div.clear {}
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

  def _rss_content article, preview
    div do
      self << "#{article.points} points by "
      a article.author, :href => article.author_link
      self << " | "
      a "#{article.comment_count} comments", :href => article.comments
    end
    hr
    _content preview
    div(:style => 'clear: both;') {'&nbsp;'}
    hr
    if CONFIG[:tagline] and article.comment_count and article.comment_count > 0
      div do
        div do
          self << "by "
          a article.top_comment_author, :href => R(HackerNews, "user", :id => article.top_comment_author)
        end
        br
        div { article.top_comment_content }
      end
    end
  end

  def _rss
    if @last_update
      self << @b.feed('xmlns' => 'http://www.w3.org/2005/Atom') do |f|
        f.title 'Kalimba'
        f.link :href => CONFIG[:canonical_url]
        id = CONFIG[:canonical_url]
        id = "#{id}/" unless id.end_with?'/'
        f.id id
        f.link :rel => 'self', :type => 'application/atom+xml', :href=> "#{CONFIG[:canonical_url]}#{R(Rss)}"
        f.subtitle CONFIG[:tagline]
        f.updated @last_update.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
        f.author do |a|
          a.name CONFIG[:author_name]
          a.email CONFIG[:author_email]
          a.uri CONFIG[:author_uri]
        end
        f.generator 'Kalimba'
        @articles.each do |article, preview_row, preview|
          f.entry do |i|
            i.title article.title
            i.link article.link, :href => Kalimba::Models::Article.normalize_url(article.link)
            id = Kalimba::Models::Article.normalize_url(article.link)
            id = "#{id}/" unless id.end_with?'/'
            i.id id
            if preview_row
              i.updated preview_row.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
              i.published preview_row.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
            else
              i.updated @last_update.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
              i.published @last_update.created_at.utc.strftime("%Y-%m-%dT%H:%S:%MZ")
            end
            i.author do |author|
              author.name article.author
              author.uri article.author_link
            end
            content = render(:_rss_content, article, preview) if preview
            if content
              i.content content, :type => 'html'
            end
            if preview
              i.summary preview.description, :type => 'html'
            end
          end
        end
      end
    end
  end

  def error
    div.error do
      center do
        h1 "We're Sorry"
        img :src => R(Image, 'kalimba-piano.jpg'), :alt => 'not found'
        h1 "#{@code} - #{@message}"
      end
    end
  end

  def _keys_js
    self <<<<-"END"
jQuery(document).ready(function($) {
  $('.top_comment_link').click(function(event) {
    event.preventDefault();
    $(this).parent().find('.top_comment').toggle('fast');
  });

  $.facebox.settings.loadingImage = '#{R(Image, 'loading.gif')}'
  $.facebox.settings.closeImage = '#{R(Image, 'closelabel.png')}'
  $.facebox.settings.opacity = 0.2
  $.facebox.settings.faceboxHtml = '\
    <div id="facebox" style="display:none;"> \
      <div class="popup"> \
        <div class="content"> \
        </div> \
        <a href="#" class="close"><img src="#{R(Image, 'closelabel.png')}" title="close" class="close_image" /></a> \
      </div> \
    </div>'

  function State() {
    this.index = -1
    this.max = $('ul.article_list > li.article').size();
    this.toggle = 'fast';
  }

  State.prototype.current = function() {
    return $('a[name='+(this.index+1)+']').parent();
  }

  State.prototype.inRange = function() {
    return this.index >= 0 && this.index < this.max
  }

  State.prototype.up = function() {
    if (this.index > 0) {
      this.index--;
      this.index %= this.max;
      this.highlight();
    }
  }
  State.prototype.down = function() {
    if (this.index < this.max - 1) {
      this.index++;
      this.index %= this.max;
      this.highlight();
    }
  }
  State.prototype.toggle_content = function() {
    if (this.inRange()) {
      this.current().find('.embedly_content').toggle(this.toggle)
    }
  }
  State.prototype.toggle_comments = function() {
    if (this.inRange()) {
      this.current().find('.top_comment').toggle(this.toggle)
    }
  }
  State.prototype.goto_comments = function() {
    if (this.inRange()) {
      window.open(this.current().find('.comment_link').attr('href'))
    }
  }
  State.prototype.follow = function(shift) {
    if (this.inRange()) {
      var href = this.current().find('.embedly_title').find('a').last().attr('href');
      if (shift) {
        window.open(href);
      } else {
        document.location.href = href;
      }
    }
  }
  State.prototype.highlight = function() {
    $('.article_rank').removeClass('selected');
    if (this.inRange()) {
      state.current().find('.article_rank').addClass('selected');
      document.location.href = '#'+(this.index+1);
    }
  }
  State.prototype.help = function() {
    $.facebox({div: '#shortcuts'});
  }
  var state = new State();

  // keypress mappings
  var KEYS = {
    106: 'down',            // j
    107: 'up',              // k
    99:  'toggle_comments', // c
    67:  'goto_comments',   // C
    100: 'toggle_content',  // d
    13:  'follow',          // enter
    63:  'help'             // ?
  }
  // keyup mappings
  var ARROWS = {
    37:  'up',              // up arrow
    39:  'down'             // down arrow
  }

  $(document).keypress(function(event) {
    var command = KEYS[event.which];
    if (command) {
      event.preventDefault();
      state[command](event.shiftKey);
    }
  });

  $(document).keyup(function(event) {
    var command = ARROWS[event.keyCode];
    if (command) {
      event.preventDefault();
      state[command](event.shiftKey);
    }
  });

  $('a[name=keys]').click(function() {
    state.help();
  });

  if (document.location.hash) {
    state.index = document.location.hash.substring(1) - 1;
    state.highlight();
  }
});
    END
  end

  def _shareaholic_js
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

  def _analytics_js
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

def Kalimba.create
  Kalimba::Models.create_schema
end
