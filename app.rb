require "sinatra"
require "koala"
require "pg"

require "data_mapper"

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

get '/' do
  page = params[:p] || 'index'
  erb :"#{page}"
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
