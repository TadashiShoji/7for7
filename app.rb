require "sinatra"
require "koala"
require "pg"

require "data_mapper"
require "./lib/authorization"

enable :sessions
set :raise_errors, false
set :show_exceptions, false

# database connection from heroku
DataMapper.setup(:default, ENV["DATABASE_URL"])

class Email

  include DataMapper::Resource

  property :id,             Serial
  property :username,       String
  property :subscribed,     Boolean
  property :email,          String, :required => false
  property :created_at,    DateTime,  :required => false

end

class Group
  
  include DataMapper::Resource
  
  property  :id,            Serial
  property  :name,          String, :required => true
  property  :is_active,     Boolean, :required => true
  property  :promo_code,    String, :required => true
  property  :created_at,    DateTime,  :required => false
  property  :updated_at,    DateTime,  :required => false

  has n, :products, :constraint => :destroy
  has n, :promotions, :constraint => :destroy
    
end

class Product

  include DataMapper::Resource

  property  :id,            Serial
  property  :productname,   String, :required => true
  property  :description,   String, :required => true
  property  :picture,       String, :required => true
  property  :created_at,    DateTime,  :required => false
  property  :updated_at,    DateTime,  :required => false

  belongs_to :group
  has n, :votes, :constraint => :destroy

end

class Promotion

  include DataMapper::Resource

  property  :id,            Serial
  property  :productname,   String, :required => true
  property  :description,   String, :required => true
  property  :picture,       String, :required => true
  property  :url,           String, :required => false
  property  :created_at,    DateTime,  :required => false
  property  :updated_at,    DateTime,  :required => false

  belongs_to :group

end

class Vote

  include DataMapper::Resource

  property  :id,            Serial
  property  :email,         String, :required => false
  property  :ip_address,    String
  property  :subscribed,    Boolean
  property  :username,      String
  property  :created_at,    DateTime 

  belongs_to :product

end


# Create or upgrade the database all at once
DataMapper.auto_upgrade!

# Scope defines what permissions that we are asking the user to grant.
# In this example, we are asking for the ability to publish stories
# about using the app, access to what the user likes, and to be able
# to use their pictures.  You should rewrite this scope with whatever
# permissions your app needs.
# See https://developers.facebook.com/docs/reference/api/permissions/
# for a full list of permissions
FACEBOOK_SCOPE = 'user_likes,user_photos'

unless ENV["FACEBOOK_APP_ID"] && ENV["FACEBOOK_SECRET"]
  abort("missing env vars: please set FACEBOOK_APP_ID and FACEBOOK_SECRET with your app credentials")
end

before do
  # HTTPS redirect
  if settings.environment == :production && request.scheme != 'https'
    redirect "https://#{request.env['HTTP_HOST']}"
  end
end

helpers do
  include Sinatra::Authorization

  def host
    request.env['HTTP_HOST']
  end

  def scheme
    request.scheme
  end

  def url_no_scheme(path = '')
    "//#{host}#{path}"
  end

  def url(path = '')
    "#{scheme}://#{host}#{path}"
  end

  def authenticator
    @authenticator ||= Koala::Facebook::OAuth.new(ENV["FACEBOOK_APP_ID"], ENV["FACEBOOK_SECRET"], url("/auth/facebook/callback"))
  end

  # allow for javascript authentication
  def access_token_from_cookie
    authenticator.get_user_info_from_cookies(request.cookies)['access_token']
  rescue => err
    warn err.message
  end

  def access_token
    session[:access_token] || access_token_from_cookie
  end


end

# the facebook session expired! reset ours and restart the process
error(Koala::Facebook::APIError) do
  session[:access_token] = nil
  redirect "/auth/facebook"
end


post "/" do
  @signed_request = authenticator.parse_signed_request(params[:signed_request])
  liked_page = @signed_request['page']['liked']
  if liked_page 
    redirect "/"
  else
    erb :locked
  end
end

get "/" do
  # Get base API Connection
  @graph  = Koala::Facebook::API.new(access_token)

  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])

  if access_token
    @user    = @graph.get_object("me")
    @friends = @graph.get_connections('me', 'friends')
    @photos  = @graph.get_connections('me', 'photos')
    @likes   = @graph.get_connections('me', 'likes').first(4)
    set :user_name, @user['me']['username']
    set :email, @user['me']['email']

    # for other data you can always run fql
    @friends_using_app = @graph.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid in (SELECT uid2 FROM friend WHERE uid1 = me()) AND is_app_user = 1")
  end
  erb :index
end

# used by Canvas apps - redirect the POST to be a regular GET
post "/" do
  redirect "/"
end

# used to close the browser window opened to post to wall/send to friends
get "/close" do
  "<body onload='window.close();'/>"
end

# Doesn't actually sign out permanently, but good for testing
get "/preview/logged_out" do
  session[:access_token] = nil
  request.cookies.keys.each { |key, value| response.set_cookie(key, '') }
  redirect '/'
end


# Allows for direct oauth authentication
get "/auth/facebook" do
  session[:access_token] = nil
  redirect authenticator.url_for_oauth_code(:permissions => FACEBOOK_SCOPE)
end

get '/auth/facebook/callback' do
  session[:access_token] = authenticator.get_access_token(params[:code])
  redirect '/'
end

post '/email/create' do
  @email = Email.new(params[:email])
  if @email.save
    redirect "/vote"
  else
    redirect "/admin"
  end
end

get '/vote' do
  @groups = Group.first(:is_active => true)
  erb :"vote"
end

get '/voted' do 
  @groups = Group.first(:is_active => true)
  erb :"voted"
end

get '/end' do
  erb :"theend"
end

get '/admin' do
  require_admin
  page = params[:p] || 'index'
  @groups = Group.all(:order => [:id.asc])
  @emails = Email.all(:order => [:id.asc])
  erb :"admin/#{page}", :layout => :admin
end

get '/admin/day/new' do
  require_admin
  page = params[:p] || 'new'
  @title = "Create new Day"
  erb :"admin/day/#{page}", :layout => :admin
end

post '/admin/day/create' do
  require_admin
  @day = Group.new(params[:day])
  if @day.save
    redirect "/admin/day/show/#{@day.id}"
  else
    redirect "/admin"
  end
end

get '/admin/day/show/:id' do
  require_admin
  page = params[:p] || 'show'
  @day = Group.get(params[:id])
  if @day
  erb :"admin/day/#{page}", :layout => :admin
  else
    redirect('/admin')
  end
end

get '/admin/day/delete/:id' do
  require_admin
  day = Group.get(params[:id])
  unless day.nil?
    day.destroy
  end
  redirect('/admin')
end

get '/admin/day/edit/:id' do
  require_admin
  page = params[:p] || 'edit'
  @day = Group.get(params[:id])
  if @day
    erb :"admin/day/#{page}", :layout => :admin
  else
    redirect('/admin')
  end  
end

post '/admin/day/update' do
  require_admin
  @day = Group.get(params[:id])
  if @day.update(params[:day])
    redirect "/admin/day/show/#{@day.id}"
  else 
    redirect('/admin')
  end  
end


get '/admin/day/products/new/:dayid' do
  require_admin
  page = params[:p] || 'new'
  @day = Group.get(params[:dayid])
  @title = "Create new product"
  erb :"admin/products/#{page}", :layout => :admin
end

post '/admin/day/products/create/:dayid' do
  require_admin
  day = Group.get(params[:dayid])
  @product = day.products.new(params[:product])
  if @product.save
    redirect "/admin/day/show/#{day.id}"
  else
    redirect "/admin"
  end
end

get '/admin/day/products/show/:dayid/:id' do
  require_admin
  page = params[:p] || 'show'
  @day = Group.get(params[:dayid])
  @product = @day.products.get(params[:id])
  if @product
  erb :"admin/products/#{page}", :layout => :admin
  else
    redirect('/admin')
  end
end

get '/admin/day/products/edit/:dayid/:id' do
  require_admin
  page = params[:p] || 'edit'
  @day = Group.get(params[:dayid])
  @product = @day.products.get(params[:id])
  if @product
  erb :"admin/products/#{page}", :layout => :admin
  else
    redirect('/admin')
  end
end

post '/admin/day/products/update' do
  require_admin
  @day = Group.get(params[:dayid])
  @product = @day.products.get(params[:id])
  if @product.update(params[:product])
    redirect "/admin/day/products/show/#{@day.id}/#{@product.id}"
  else 
    redirect('/admin')
  end  
end

get '/admin/day/products/delete/:dayid/:id' do
  require_admin
  page = :dayid
  day = Group.get(params[:dayid])
  product = day.products.get(params[:id])
  unless product.nil?
    product.destroy
  end
  redirect "/admin/day/show/#{day.id}"
end

get '/admin/day/products/vote/:dayid/:id' do
  require_admin
  day = Group.get(params[:dayid])
  @product = day.products.get(params[:id])
  @vote = @product.votes.new(:email => 'aznlucidx@gmail.com', :ip_address => '192.168.0.1', :subscribed => 'true', :username => 'misfire')
  if @vote.save
    redirect "/admin/day/show/#{day.id}"
  else
    redirect "/admin"
  end
end

post '/vote/:id' do
  day = Group.get(params[:dayid])
  @product = Product.get(params[:id])
  @vote = @product.votes.new(params[:votes])
    if @vote.save
    redirect "/voted"
  else
    redirect "/vote"
  end
end

get '/admin/day/promotions/show/:dayid/:id' do
  require_admin
  page = params[:p] || 'show'
  @day = Group.get(params[:dayid])
  @promotion = @day.promotions.get(params[:id])
  if @promotion
  erb :"admin/promotions/#{page}", :layout => :admin
  else
    redirect('/admin')
  end
end

get '/admin/day/promotions/new/:dayid' do
  require_admin
  page = params[:p] || 'new'
  @day = Group.get(params[:dayid])
  @title = "Create new promotion"
  erb :"admin/promotions/#{page}", :layout => :admin
end

post '/admin/day/promotions/create/:dayid' do
  require_admin
  day = Group.get(params[:dayid])
  @promotion = day.promotions.new(params[:promotion])
  if @promotion.save
    redirect "/admin/day/show/#{day.id}"
  else
    redirect "/admin"
  end
end

get '/admin/day/promotions/edit/:dayid/:id' do
  require_admin
  page = params[:p] || 'edit'
  @day = Group.get(params[:dayid])
  @promotion = @day.promotions.get(params[:id])
  if @promotion
  erb :"admin/promotions/#{page}", :layout => :admin
  else
    redirect('/admin')
  end
end

post '/admin/day/promotions/update' do
  require_admin
  @day = Group.get(params[:dayid])
  @promotion = @day.promotions.get(params[:id])
  if @promotion.update(params[:promotion])
    redirect "/admin/day/promotions/show/#{@day.id}/#{@promotion.id}"
  else 
    redirect('/admin')
  end  
end

get '/admin/day/promotions/delete/:dayid/:id' do
  require_admin
  page = :dayid
  day = Group.get(params[:dayid])
  promotion = day.promotions.get(params[:id])
  unless promotion.nil?
    promotion.destroy
  end
  redirect "/admin/day/show/#{day.id}"
end

get '/admin/day/votes/show/:dayid/:id' do
  require_admin
  @day = Group.get(params[:dayid])
  @product = @day.products.get(params[:id])
  @votes = @product.votes.all
  erb :"admin/votes/show", :layout => :admin
end

get '/vote' do
"this a vote page"
end

get '/vote:id' do

end

get '/thanks/' do
"this is the thank you page"
end
