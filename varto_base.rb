#!/usr/bin/env ruby
# coding: utf-8
require "rubygems"
require "sinatra"
require "twitter_oauth"
require "addressable/uri"
require "dm-core" 
require "dm-validations" 
require "dm-aggregates" 
require "dm-timestamps" 
require "dm-serializer" 
require "dm-migrations"
require "erb"

before do
  @user ||= 
    if session[:user_id]
      User.get(session[:user_id])
    else
      false
    end

    @client = TwitterOAuth::Client.new(
      :consumer_key => ENV['CONSUMER_KEY'] || @@config['consumer_key'],
      :consumer_secret => ENV['CONSUMER_SECRET'] || @@config['consumer_secret'],
      :token => @user ? @user.access_token : "",
      :secret => @user ? @user.access_secret : ""
    )
end

helpers do 
  def partial(name, options={})
    erb("_#{name.to_s}".to_sym, options.merge(:layout => false))
  end
  def protected!
    throw(:halt, [401, "Not authorized\n"]) unless @user
  end
  def authorized!
    throw(:halt, [401, "Not authorized\n"]) unless @user && @user.admin
  end
  def truncate(text, length)
    omission = "..."
    if text
      l = length - omission.length
      chars = text
      (chars.length > length ? chars[0...l] + omission : text).to_s
    end
  end
end

get '/' do
  redirect '/links' if @user
  erb :index
end

get '/about' do
  erb :about
end

get '/links' do
  protected!
  @links = Link.all(:user_id => @user.id )
  erb "links/index".to_sym
end

get '/links/new' do
  protected!
  erb "links/new".to_sym
end

post '/links' do
  protected!

  @link = Link.create_url({:user_id => @user.id, :title => params[:title], :description => params[:description]}, 6)
  target_1 = @link.targets.create(:target => params[:target_1])
  target_2 = @link.targets.create(:target => params[:target_2])

  redirect '/links/' + @link.short
end

get '/links/:short' do
  protected!
  if @link = Link.first(:short=>params[:short], :user_id => @user.id)
    erb "links/show".to_sym
  else
    status(404) 
  end
end

get '/connect' do
  request_token = @client.request_token(
    :oauth_callback => ENV['CALLBACK_URL'] || @@config['callback_url']
  )
  session[:request_token] = request_token.token
  session[:request_token_secret] = request_token.secret
  redirect request_token.authorize_url.gsub('authorize', 'authenticate') 
end

get '/oauth_callback' do
  begin
    @access_token = @client.authorize(
      session[:request_token],
      session[:request_token_secret],
      :oauth_verifier => params[:oauth_verifier]
    )
  rescue OAuth::Unauthorized
  end

  if @client.authorized?      
      admin_user = true if @access_token.params["screen_name"] == @@config["admin_twitter_login"]
      user = User.first_or_create({ :twitter_id => @access_token.params["user_id"] }, { 
        :login => @access_token.params["screen_name"],
        :access_token => @access_token.token,
        :access_secret => @access_token.secret,
        :admin => admin_user })
    
      session[:user_id] = user.id
      redirect '/links'
    else
      redirect '/'
  end
end

get '/disconnect' do
  session[:user_id] = nil
  session[:request_token] = nil
  session[:request_token_secret] = nil
  redirect '/'
end

get '/admin' do
  authorized!
  erb "admin/index".to_sym
end

get '/admin/users' do
  authorized!
  @users = User.all
  erb "admin/users".to_sym
end

post '/admin/users/ban' do
  authorized!
  @user = User.get(params[:user_id])
  if @user.banned = true
    @user.update_attributes(:banned => false)
  else
    @user.update_attributes(:banned => true)
  end
  redirect '/admin/users'
end

get '/admin/links' do
  authorized!
  @links = Link.all
  erb "admin/links".to_sym
end

get '/:link' do 
  if link = Link.first(:short=>params[:link])
    if link.user.banned?
      status(404)
    else
      hit_and_render(rand_from_weighted(link.targets))
    end
  else
    status(404) 
  end
end

def rand_from_weighted(targets)
  total_weight = targets.inject(0) { |sum,target| sum+target.weight }
  running_weight = 0
  n = rand*total_weight
  targets.each do |target|
    return target if n > running_weight && n <= running_weight+target.weight
    running_weight += target.weight
  end
end

def hit_and_render(target, options={})
  add_hit = target.hits + 1
  target.update_attributes(:hits => add_hit)
  Visit.create_visit(target, request)
  @target = target
  erb :page, :layout => false
end

error do   
  'Sorry there was a nasty error - ' + env['sinatra.error'].name
end

class User
  include DataMapper::Resource
  property :id,                         Serial,   :index => true
  property :twitter_id,                 String,   :length => 0..255
  property :login,                      String,   :length => 0..20
  property :access_token,               String,   :length => 0..255
  property :access_secret,              String,   :length => 0..255
  property :admin,                      Boolean,  :default => false
  property :banned,                     Boolean,  :default => false
  property :created_at,                 DateTime
  property :updated_at,                 DateTime
end

class Link
  CHARS = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "1", "2", "3", "4", "5", "6", "7", "8", "9"] unless defined?(CHARS)
  include DataMapper::Resource
  property :id,               Serial
  property :user_id,          Integer,  :index => true, :null => false
  property :short,            String,   :index => true, :null => false
  property :title,            String,   :length => 0..255
  property :description,      String,   :length => 0..1000
  property :masked,           Boolean,  :default => true
  property :active,           Boolean,  :default => true
  property :created_at,       DateTime
  property :updated_at,       DateTime

  has n, :targets
  belongs_to :user

  def self.create_url(params, length)
    link = Link.new params
    short = Array.new(length){||CHARS[rand(CHARS.size)]}.join
    while Link.first(:short=>short) != nil
      short = Array.new(length){||CHARS[rand(CHARS.size)]}.join
    end
    link.short = short
    link.save && link 
  end

  def self.create_custom(params, short)
    link = Link.new params
    link.short = short
    link.save && link
  end

  def url
    "http://" + @@config['host_addr'] + "/" + short
  end
end

class Target 
  include DataMapper::Resource
  property :id,               Serial
  property :link_id,          Integer,  :index => true
  property :target,           String,   :format => :url, :length => 0..1500, :index => true
  property :weight,           Integer,  :default => 50,  :length => 0..100 
  property :hits,             Integer,  :default => 0

  belongs_to :link
end

class Visit
  include DataMapper::Resource
  property :id,             Serial
  property :link_id,        Integer, :index => true
  property :target_id,      Integer, :index => true
  property :user_id,        Integer, :index => true
  property :remote_address, String, :length => 0..255
  property :user_agent,     String, :length => 0..255
  property :http_referer,   String, :length => 0..255
  property :imported_at,    DateTime
  property :created_at,     DateTime
  
  def self.create_visit(target, request)
    visit = Visit.new
    visit.link_id = target.link.id
    visit.target_id = target.id
    visit.user_id = target.link.user_id
    visit.remote_address = request.env["REMOTE_ADDR"].gsub(/,.+/,'')
    visit.user_agent = request.env["HTTP_USER_AGENT"]
    visit.http_referer = request.env['HTTP_REFERER']
    visit.save
  end
end

configure do
  set :sessions, true
  @@config = YAML.load_file("config/#{Sinatra::Application.environment}.config.yml") rescue nil || {}
  DataMapper.setup(:default, (ENV['DATABASE_URL'] || 'mysql://root@localhost/varto_base'))
  DataMapper.auto_upgrade!
end