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
      unless words.instance_of? Array
        # split the words on whitespaces and redo the find with that array
        fuzzy_find(words.to_s.split(/[\s\-]+/))
      else 
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
        #entity_fields = columns.map {|col| "fuzzy_ref." + col.name}.join(", ")
        entity_fields = columns.map {|col| fuzzy_ref_table + "." + col.name}.join(", ")
        
        results = find( :all, 
                        :select => "count(*) AS count, #{entity_fields}",
                        :joins => ["LEFT OUTER JOIN #{fuzzy_ref}_trigrams ON #{fuzzy_ref}_trigrams.#{fuzzy_ref}_id = #{fuzzy_ref_table}.id"],
                        :conditions => ["#{fuzzy_ref}_trigrams.token IN (?)", trigrams],
                        :group => entity_fields,
                        :order => "count DESC" )

        logger.info "fuzzy_find query found #{results.size} results"
        annotated_results = results.collect do |ref|
          # put a weight on each instance for display purpose
          def ref.fuzzy_weight=(w)
            @weight = w
          end
          def ref.fuzzy_weight
            @weight
          end
          
          # if there are no double entries then
          # i.count <= trigrams.size and i.count <= 'type'Trigrams.count
          ref.fuzzy_weight = ((ref.count.to_i * 100)/trigrams.size +
            (ref.count.to_i * 100)/fuzzy_trigram_type.send("count", :conditions => {fuzzy_ref_id => ref.id}))/2
          logger.info "weight: #{ref.fuzzy_weight}"
          ref
        end

        # Remove the results that are too "far off" what the user intended
        annotated_results.delete_if {|result| result.fuzzy_weight < fuzzy_threshold}

        annotated_results
      end
    end
  end

end
