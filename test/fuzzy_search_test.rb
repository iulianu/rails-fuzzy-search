require 'rubygems'
require 'test/unit'
require 'dm-validations'
require 'dm-aggregates'
require 'dm-timestamps'
require "fuzzy_search"

$KCODE = 'u'

DataMapper.setup(:default, {
                   :adapter  => 'sqlite3',
                   :database => "test/test.sqlite3"
                 })

if ENV['DEBUG']
  DataMapper::Logger.new(STDOUT, 0)
  DataObjects::Sqlite3.logger = DataObjects::Logger.new(STDOUT, 0) 
end

class Searchable

  # this methods hides the coupling to fuzzy-search
  def self.search(query)
    fuzzy_find(query)
  end
  
end

class UserTrigram

  include DataMapper::Resource

  property :id, Integer, :serial => true

  property :user_id, Integer

  property :token, String, :nullable => false, :length => 3

end

class User < Searchable

  include DataMapper::Resource

  def self.normalize(word)
    # strip_diacritics latin1 subset only: ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝ
    word.downcase.gsub(/ue/, "u").gsub(/ae/, "a").gsub(/oe/, "o").
      gsub(/ss/, "s").gsub(/ß/, "s").
      gsub(/À/, "a").gsub(/Á/, "a").gsub(/Â/, "a").
      gsub(/Ã/, "a").gsub(/Ä/, "a").gsub(/Å/, "a").
      gsub(/Ç/, "c").gsub(/È/, "e").gsub(/É/, "e").
      gsub(/Ê/, "e").gsub(/Ë/, "e").gsub(/Ì/, "i").
      gsub(/Í/, "i").gsub(/Î/, "i").gsub(/Ï/, "i").
      gsub(/Ñ/, "n").gsub(/Ò/, "o").gsub(/Ó/, "o").
      gsub(/Ô/, "o").gsub(/Õ/, "o").gsub(/Ö/, "o").
      gsub(/Ø/, "o").gsub(/Ù/, "u").gsub(/Ú/, "u").
      gsub(/Û/, "u").gsub(/Ü/, "u").gsub(/Ý/, "y").
      gsub(/à/, "a").gsub(/á/, "a").gsub(/â/, "a").
      gsub(/ã/, "a").gsub(/ä/, "a").gsub(/å/, "a").
      gsub(/ç/, "c").gsub(/è/, "e").gsub(/é/, "e").
      gsub(/ê/, "e").gsub(/ë/, "e").gsub(/ì/, "i").
      gsub(/í/, "i").gsub(/î/, "i").gsub(/ï/, "i").
      gsub(/ñ/, "n").gsub(/ò/, "o").gsub(/ó/, "o").
      gsub(/ô/, "o").gsub(/õ/, "o").gsub(/ö/, "o").
      gsub(/ø/, "o").gsub(/ù/, "u").gsub(/ú/, "u").
      gsub(/û/, "u").gsub(/ü/, "u").gsub(/ý/, "y").
      gsub(/ÿ/, "y")
  end

  include FuzzySearch

  fuzzy_search_attributes :firstname, :surname
  
  property :id, Integer, :serial => true

  property :surname, String, :nullable => false , :format => /^[^<'&">]*$/, :length => 32
  property :firstname, String, :nullable => false , :format => /^[^<'&">]*$/, :length => 32

end

class EmailTrigram

  include DataMapper::Resource
 
  property :id, Integer, :serial => true

  property :email_id, Integer

  property :token, String, :nullable => false, :length => 3

end

class Email < Searchable

  include DataMapper::Resource

  include FuzzySearch

  fuzzy_search_attributes :address
  
  property :id, Integer, :serial => true

  property :address, String, :nullable => false , :format => /^[^<'&">]*$/, :length => 32
 
  property :deleted_at, ParanoidDateTime

end

class FuzzySearchTest < Test::Unit::TestCase

  def setup
    User.auto_upgrade!
    UserTrigram.auto_upgrade!
    Email.auto_upgrade!
    EmailTrigram.auto_upgrade!

    create_user("meier", "kristian")
    create_user("meyer", "christian")
    create_user("mayr", "Chris")
    create_user("maier", "christoph")
    create_user("mueller", "andreas")
    create_user("other", "name")
    create_user("yet another", "name")
    create_user("last other", "name")
    Email.create(:address => "oscar@web.oa") unless Email.first(:address => "oscar@web.oa")
    Email.create(:address => "ö") unless Email.first(:address => "ö")
  end

  def test_separation_of_config
    assert User.search("meier").size > 0, "some entries"
    assert_equal 0, Email.search("meier").size, "no entries"
    assert User.search("kristian").size > 0, "some entries"
    assert_equal 0, Email.search("kristian").size, "no entries"
    assert_equal 0, User.search("oscar").size, "no entries"
    assert Email.search("oscar").size > 0, "some entries"
  end

  def test_word_normalizer
    assert_equal("aaaaaaceeeeiiiinoooooouuuuyaaaaaaceeeeiiiinoooooouuuuyy", User.normalize("ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝàáâãäåçèéêëìíîïñòóôõöøùúûüýÿ"))

    assert_equal 4, User.search("chris").size, "size"
    assert_equal 1, User.search("muell").size, "size"
    assert_equal 1, User.search("Müll").size, "size"
    assert_equal 1, User.search("mull").size, "size"
    assert_equal 1, Email.search("ö").size, "size"
    assert_equal 0, Email.search("o").size, "size"
  end

  def test_search
    assert_equal 3, User.search("meyr").size, "size"
    assert_equal 1, User.search("myr").size, "size"
    result = User.search("kristian meier")
    assert_equal "kristian", result[0].firstname, "firstname"
    assert_equal "meier", result[0].surname, "surname"
    assert_equal 100, result[0].fuzzy_weight, "fuzzy weight"
    (1..3).each do |idx|
      assert result[idx].fuzzy_weight < 100, "fuzzy weight"
    end
    assert_equal 0, User.search("").size, "size"
  end

  def test_deleted
    User.send "property", :deleted, DataMapper::Types::ParanoidBoolean
    size = User.search("other").size
    assert size > 0, "some entries"
    User.first(:surname => "other").destroy
    assert_equal size, User.search("other").size + 1, "reduced size"
  end

  private
  def create_user(surname, firstname)
    User.create(:surname => surname, :firstname => firstname) unless User.first(:surname => surname, :firstname => firstname)
  end

  puts "\n\nto trigger sql debug add DEBUG= to your commandline\n\n\n"

end
