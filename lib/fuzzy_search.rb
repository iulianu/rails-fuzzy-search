module FuzzySearch
  
  def self.included(model)
    model.extend ClassMethods
    model.extend WordNormalizerClassMethod unless model.respond_to? "normalize"
    model.send "after", :save, :fuzzy_after_save
  end

  def fuzzy_after_save
    fuzzy_ref_id = self.class.instance_variable_get(:@fuzzy_ref_id)
    trigram_type = self.class.instance_variable_get(:@fuzzy_trigram_type)
    
    #DM activerecord can use a delete method with conditions
    trigram_type.send(:all, fuzzy_ref_id => id).send("destroy!")#each{ |t| t.destroy }
    # to avoid double entries
    used_tokens = []
    self.class.instance_variable_get(:@fuzzy_props).each do |prop|
      # split the property into words (which are separated by whitespaces)
      # and generate the trigrams for each word
      attribute_get(prop).to_s.split.each do |p|
        # put a space in front and at the end to emphasize the endings
        word = ' ' + self.class.normalize(p) + ' '
        # tokenize the word and put each token in the database
        # and allow double token (without doubles the metric is 
        # slightly different)
        (0..word.length - 3).each do |idx|
          token = word[idx, 3]
          unless used_tokens.member? token
            trigram_type.send(:create, :token => token, fuzzy_ref_id => id)
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
      @@model = model
    end

    def fuzzy_search_attributes(*properties)
      # setup all the parameters which a needed later
      fuzzy_ref = @@model.name.downcase
      fuzzy_ref_id = (fuzzy_ref + "_id").to_sym
      fuzzy_ref_type_symbol = fuzzy_ref.gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase }.to_sym
      fuzzy_ref_type = Kernel::const_get(fuzzy_ref_type_symbol)
      fuzzy_trigram_type_symbol = (fuzzy_ref_type.to_s + "Trigram").gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase }.to_sym
      fuzzy_trigram_type = Kernel::const_get(fuzzy_trigram_type_symbol)

      # put the parameters as instance variable of the model
      @@model.instance_variable_set(:@fuzzy_ref, fuzzy_ref.to_sym)
      @@model.instance_variable_set(:@fuzzy_ref_id, fuzzy_ref_id)
      @@model.instance_variable_set(:@fuzzy_ref_type, fuzzy_ref_type)
      @@model.instance_variable_set(:@fuzzy_props, properties)
      @@model.instance_variable_set(:@fuzzy_trigram_type, fuzzy_trigram_type)

    end

    def fuzzy_find(words)
      unless words.instance_of? Array
        # split the words on whitespaces and redo the find with that array
        fuzzy_find(words.to_s.split)
      else 
        trigrams = []
        words.each do |w|
          word = ' ' + normalize(w) + ' '
          trigrams << (0..word.length-3).collect {|idx| word[idx,3]}
        end
        trigrams = trigrams.flatten.uniq
        
        conditions = ""
        bind_values = []
        if(paranoid_properties.size > 0)
          paranoid_properties.each do |k,v|
            if send(k).type == DataMapper::Types::ParanoidBoolean 
              conditions += " and #{k} = ?"
              bind_values << false
            else
              conditions += " and #{k} is null"
            end
          end
        end
        
        fuzzy_ref = instance_variable_get(:@fuzzy_ref)
        fuzzy_ref_id = instance_variable_get(:@fuzzy_ref_id)
        fuzzy_ref_type = instance_variable_get(:@fuzzy_ref_type)
        fuzzy_trigram_type = instance_variable_get(:@fuzzy_trigram_type)
        fuzzy_props_size = instance_variable_get(:@fuzzy_props).size
        
        query = if true 
                  "SELECT count(*) count, #{fuzzy_ref_id} FROM #{fuzzy_ref}_trigrams, #{fuzzy_ref.to_s.plural} fuzzy_ref WHERE token in ? and #{fuzzy_ref_id} = fuzzy_ref.id #{conditions} group by #{fuzzy_ref_id} order by count desc"
                else
                  #DM : will not work with activerecord like this
                  "SELECT count(*) count, #{fuzzy_ref_id} FROM #{fuzzy_ref}_trigrams WHERE token in ? group by #{fuzzy_ref_id} order by count desc"
                end
        repository.adapter.query(query, trigrams, bind_values).collect do |i|
            #DM : activerecord needs a find method instead
          ref = fuzzy_ref_type.send("get!", i.send(fuzzy_ref_id)) 

          # put a weight on each instance for display purpose
          # TODO maybe there is a better name instead of weight
          def ref.fuzzy_weight=(w)
            @weight = w
          end
          def ref.fuzzy_weight
            @weight
          end
          
          # if there are no double entries then
          # i.count <= trigrams.size and i.count <= 'type'Trigrams.count
          ref.fuzzy_weight = ((i.count * 100)/trigrams.size +
            (i.count * 100)/fuzzy_trigram_type.send("count", fuzzy_ref_id => ref.id))/2
          ref
        end
      end
    end
  end

end
