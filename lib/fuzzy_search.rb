# vim:ts=2:sw=2:et

module FuzzySearch

  def self.included(model)
    model.extend ClassMethods
    model.extend WordNormalizerClassMethod unless model.respond_to? "normalize"
    model.send :after_save, :extract_trigrams!
  end

  def extract_trigrams!
    trigram_type = self.class.fuzzy_trigram_type
    trigram_type.send(:delete_all, ["#{self.class.fuzzy_ref_id} = ?", id])

    # to avoid double entries
    used_tokens = []
    self.class.fuzzy_props.each do |prop|
      prop_value = send(prop)
      next if prop_value.nil?
      # split the property into words (which are separated by whitespaces)
      # and generate the trigrams for each word
      prop_value.to_s.split(/[\s\-]+/).each do |p|
        # put a space in front and at the end to emphasize the endings
        word = ' ' + self.class.normalize(p) + ' '
        # tokenize the word and put each token in the database
        # and allow double token (without doubles the metric is 
        # slightly different)
        word_as_chars = word.mb_chars
        (0..word_as_chars.length - 3).each do |idx|
          token = word_as_chars[idx, 3].to_s
          unless used_tokens.member? token
            trigram_type.send(:create, :token => token, self.class.fuzzy_ref_id => id)
            used_tokens << token
          end
        end
      end
    end
  end

  module WordNormalizerClassMethod
    def normalize(word) word.downcase end
  end

  module ClassMethods
    def self.extended(model)
      model.class_eval do
        cattr_accessor :fuzzy_ref
        self.fuzzy_ref = model.name.underscore
        has_many fuzzy_trigram_type_symbol.to_s.tableize.to_sym
        named_scope :fuzzy_find_scope, lambda { |words| generate_fuzzy_find_scope_params(words) }
      end
    end

    def fuzzy_ref_id; (fuzzy_ref + "_id").to_sym; end
    def fuzzy_ref_type_symbol; fuzzy_ref.gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase }.to_sym; end
    def fuzzy_ref_type; Kernel::const_get(fuzzy_ref_type_symbol); end
    def fuzzy_ref_table; fuzzy_ref.pluralize; end
    def fuzzy_trigram_type_symbol; (fuzzy_ref_type.to_s + "Trigram").gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase }.to_sym; end
    def fuzzy_trigram_type; Kernel::const_get(fuzzy_trigram_type_symbol); end

    def fuzzy_search_attributes(*properties)
      cattr_accessor :fuzzy_props
      self.fuzzy_props = properties
      cattr_accessor :fuzzy_threshold
      self.fuzzy_threshold = 5
    end

    def fuzzy_find(words)
      fuzzy_find_scope(words).all
    end

    private

    def generate_fuzzy_find_scope_params(words)
      return {} unless words != nil
      words = words.strip.to_s.split(/[\s\-]+/) unless words.instance_of? Array
      return {} unless words.size > 0

      trigrams = []
      words.each do |w|
        word = ' ' + normalize(w) + ' '
        word_as_chars = word.mb_chars
        trigrams << (0..word_as_chars.length-3).collect {|idx| word_as_chars[idx,3].to_s}
      end
      trigrams = trigrams.flatten.uniq

      # Transform the list of columns in the searchable entity into 
      # a SQL fragment like:
      # "fuzzy_ref.id, fuzzy_ref.field1, fuzzy_ref.field2, ..."
      entity_fields = columns.map {|col| fuzzy_ref_table + "." + col.name}.join(", ")

      # The SQL expression for calculating fuzzy_weight
      # Has to be used multiple times because some databases (i.e. Postgres) do not support HAVING on named SELECT fields
      fuzzy_weight_expr = "(((count(*)*100.0)/#{trigrams.size}) + " +
        "((count(*)*100.0)/(SELECT count(*) FROM #{fuzzy_ref}_trigrams WHERE #{fuzzy_ref}_id = #{fuzzy_ref_table}.id)))/2.0"

      return {
        :select => "#{fuzzy_weight_expr} AS fuzzy_weight, #{entity_fields}",
        :joins => ["LEFT OUTER JOIN #{fuzzy_ref}_trigrams ON #{fuzzy_ref}_trigrams.#{fuzzy_ref}_id = #{fuzzy_ref_table}.id"],
        :conditions => ["#{fuzzy_ref}_trigrams.token IN (?)", trigrams],
        :group => entity_fields,
        :order => "fuzzy_weight DESC",
        :having => "#{fuzzy_weight_expr} >= #{fuzzy_threshold}"
      }
    end
  end

end
