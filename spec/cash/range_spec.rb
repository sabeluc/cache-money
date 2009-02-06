require File.join(File.dirname(__FILE__), '..', 'spec_helper')

module Cash
  describe 'Range' do
    describe '#initialize' do
      it 'does not support ranges by default' do
        Story.cache_config.indices.first.supports_ranges?.should be_false
      end
      
      it 'supports ranges for specified attributes' do
        Fable.cache_config.indices.first.attributes.should == ["num_pages"]
        Fable.cache_config.indices.first.supports_ranges?.should be_true
      end
    end
    
    describe '#create' do
      describe 'when the index supports ranges' do
        describe 'when the cache is empty' do 
          it 'writes records into the regurlar cache at primary key' do
            fable = Fable.create!(:author => 'Sam', :num_pages => '123')
            Fable.get("id/#{fable.id}").should == [fable]
          end
        
          it 'writes records into the range cache at the correct keys' do
            fable = Fable.create!(:author => 'Sam', :num_pages => '6')
            Fable.get("num_pages/6").data.should == [fable.id]
          end
        
          it 'does not write individual objects into the range cache for nil collections' do
            fable = Fable.create!(:author => 'Sam', :num_pages => '106')
            Fable.get("num_pages/1**").should == nil
            Fable.get("num_pages/10*").should == nil
            Fable.get("num_pages/106").data.should == [fable.id]
          end
          
          it 'does write objects into empty collections' do
            Fable.set("num_pages/1**", RangeData.new([]))
            fable = Fable.create!(:author => 'Sam', :num_pages => '106')
            Fable.get("num_pages/1**").data.should == [fable.id]
          end
        
          it 'does write individual objects into the range cache for populated collections' do
            Fable.set("num_pages/1**", RangeData.new([99]))
            fable = Fable.create!(:author => 'Sam', :num_pages => '106')
            Fable.get("num_pages/1**").data.sort.should == [99, fable.id].sort
            Fable.get("num_pages/10*").should == nil
            Fable.get("num_pages/106").data.should == [fable.id]
          end
        
          it 'appends records to range cache when keys match' do
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '60')
            fable2 = Fable.create!(:author => 'Kumar', :num_pages => '60')
            Fable.get("num_pages/60").data.should == [fable1.id, fable2.id]
          end
        
          it 'adds record to all nodes where the new record should appear' do
            fables = (0..9).to_a.collect { |i| Fable.create!(:num_pages => i) }
            (0..9).to_a.each { |i| Fable.get("num_pages/#{i}").data.should == [fables[i].id] }
            Fable.find(:all, :conditions => { :num_pages => 0..9 })
            Fable.get("num_pages/*").data.should == fables.collect { |f| f.id }
            new_fable = Fable.create!(:num_pages => 7)
            Fable.get("num_pages/7").data.should include(new_fable.id)
            Fable.get("num_pages/*").data.should include(new_fable.id)
          end
        end
        
        describe 'when the cache is populated' do
          it 'adds the new record to all keys that should contain it' do
            with_arity(4) do
              (0..15).to_a.collect { |i| Fable.create!(:num_pages => i) }
              Fable.find(:all, :conditions => { :num_pages => 0..15 })
              fable = Fable.create(:num_pages => 0)
              Fable.get("num_pages/0").data.should include(fable.id)
              Fable.get("num_pages/*").data.should be_nil
              Fable.get("num_pages/*").parent.should_not be_nil
              Fable.get("num_pages/**").data.should include(fable.id)
              Fable.get("num_pages/**").parent.should be_nil
              Fable.get("num_pages/***").should be_nil              
            end
          end
          
          it 'preserves parent pointers when populating left-branch nodes' do
            with_arity(4) do
              Fable.find(:all, :conditions => { :num_pages => 0..63 })
              Fable.get("num_pages/***").data.should == []
              Fable.get("num_pages/**").parent.should == "num_pages/***"
              Fable.get("num_pages/**").data.should be_nil
              Fable.get("num_pages/*").parent.should == "num_pages/**"
              Fable.get("num_pages/*").data.should be_nil

              fable2 = Fable.create(:num_pages => 3)
              Fable.find(:all, :conditions => { :num_pages => 0..3 })
              Fable.get("num_pages/***").data.should == [fable2.id]
              Fable.get("num_pages/**").parent.should == "num_pages/***"
              Fable.get("num_pages/**").data.should be_nil
              Fable.get("num_pages/*").parent.should == "num_pages/**"
              Fable.get("num_pages/*").data.should == [fable2.id]
            end
          end
          
          it 'skips empty intermediate left branch nodes' do
            with_arity(4) do
              Fable.find(:all, :conditions => { :num_pages => 0..63 })
              Fable.find(:all, :conditions => { :num_pages => 0..3 })
              Fable.get("num_pages/***").data.should == []
              Fable.get("num_pages/***").parent.should be_nil
              Fable.get("num_pages/**").data.should be_nil
              Fable.get("num_pages/**").parent.should == "num_pages/***"
              Fable.get("num_pages/*").data.should == []
              Fable.get("num_pages/*").parent.should == "num_pages/**"
              
              fable = Fable.create!(:num_pages => 1)
              Fable.get("num_pages/****").should be_nil
              Fable.get("num_pages/***").data.should == [fable.id]
              Fable.get("num_pages/**").data.should be_nil
              Fable.get("num_pages/*").data.should == [fable.id]
            end
          end
        end
      end
      
      describe 'when the index does not support ranges' do
        it 'writes records into the regurlar cache at primary key' do
          tale = Tale.create!(:title => 'I am debonair', :height => 10)
          Tale.get("id/#{tale.id}").should == [tale]
        end
        
        it 'does not write into the range cache' do
          tale = Tale.create!(:title => 'I am debonair', :height => 10)
          Tale.get("height/1*").should == nil
          Tale.get("height/10").should == nil
        end
      end
    end
    
    describe 'after update' do
      describe 'when the index supports ranges' do
        it 'removes objects from range cache at old keys' do
          Fable.set("num_pages/12*", RangeData.new([99]))
          fable = Fable.create!(:author => 'Sam', :num_pages => '123')
          Fable.get("num_pages/12*").data.should == [fable.id, 99]
          Fable.get("num_pages/123").data.should == [fable.id]
          fable.update_attributes(:num_pages => '145')
          Fable.get("num_pages/12*").data.should == [99]
          Fable.get("num_pages/123").data.should == []
        end
        
        it 'adds objects to the range cache at the new keys' do
          Fable.set("num_pages/14*", RangeData.new([99]))
          fable = Fable.create!(:author => 'Sam', :num_pages => '123')
          fable.update_attributes(:num_pages => '145')
          Fable.get("num_pages/14*").data.should == [fable.id, 99]
          Fable.get("num_pages/145").data.should == [fable.id]
        end
        
        it 'updates the left branch correctly' do
          with_arity(4) do
            fable = Fable.create!(:num_pages => 0)
            Fable.find(:all, :conditions => { :num_pages => 0..63 })
            Fable.find(:all, :conditions => { :num_pages => 0..3 })
            Fable.get("num_pages/*").data.should == [fable.id]
            
            fable.update_attributes(:num_pages => 16)
            Fable.get("num_pages/***").data.should == [fable.id]
            Fable.get("num_pages/**").data.should be_nil
            Fable.get("num_pages/*").data.should == []
          end
        end
      end
    end
    
    describe '#destroy' do
      describe 'when the index supports ranges' do
        it 'removes objects from the range cache' do
          Fable.set("num_pages/1**", RangeData.new([99]))
          Fable.set("num_pages/14*", RangeData.new([100]))
          
          fable1 = Fable.create!(:author => 'Sam', :num_pages => '123')
          Fable.get("num_pages/1**").data.sort.should == [fable1.id, 99].sort
          Fable.get("num_pages/12*").should be_nil
          Fable.get("num_pages/123").data.should == [fable1.id]
          
          fable2 = Fable.create!(:author => 'Linda', :num_pages => '145')
          Fable.get("num_pages/1**").data.sort.should == [fable1.id, fable2.id, 99].sort
          Fable.get("num_pages/14*").data.should == [fable2.id, 100]
          Fable.get("num_pages/145").data.should == [fable2.id]
                    
          fable1.destroy
          Fable.get("num_pages/1**").data.sort.should == [fable2.id, 99].sort
          Fable.get("num_pages/12*").should be_nil
          Fable.get("num_pages/123").data.should == []
          Fable.get("num_pages/14*").data.sort.should == [fable2.id, 100].sort
          Fable.get("num_pages/145").data.should == [fable2.id]
        end
        
        it 'deletes from the left branch correctly' do
          with_arity(4) do
            fable = Fable.create!(:num_pages => 0)
            Fable.find(:all, :conditions => { :num_pages => 0..63 })
            Fable.find(:all, :conditions => { :num_pages => 0..3 })
            Fable.get("num_pages/*").data.should == [fable.id]
            
            fable.destroy
            Fable.get("num_pages/***").data.should == []
            Fable.get("num_pages/**").data.should be_nil
            Fable.get("num_pages/*").data.should == []
          end
        end
      end
    end
    
    describe '#find(:all, :conditions => {:date => (start..end)}, ...)' do
      describe 'when the index does not support ranges' do
        it 'does not create a bogus cache entry for id' do
          story1 = Story.create!(:title => "I am terse")
          story2 = Story.create!(:title => "I am verbose")
          story3 = Story.create!(:title => "I am grandiloquent")
          $memcache.flush_all
          Story.find(:all, :conditions => { :id => (story2.id..story3.id) })
          Story.get("id/2..3").should be_nil
        end        
      end
      
      describe 'the abstract query class' do
        it 'calculates range cache keys correctly' do
          query = Query::Select.new(nil, nil, nil)
          fake_index = Object.new
          
          stub(fake_index).arity { 10 }
          query.send(:range_cache_keys, fake_index, [["attr", 0..1000]]).last.sort.should ==
              ["attr/***", "attr/1000"].sort
          query.send(:range_cache_keys, fake_index, [["attr", 0..211]]).last.sort.should ==
              ["attr/211", "attr/210", "attr/20*", "attr/1**", "attr/**"].sort
          query.send(:range_cache_keys, fake_index, [["attr", 1..99]]).last.sort.should ==
              ["attr/9*", "attr/8*", "attr/7*", "attr/6*", "attr/5*", "attr/4*", 
               "attr/3*", "attr/2*", "attr/1*", "attr/9", "attr/8", "attr/7", "attr/6", 
               "attr/5", "attr/4", "attr/3", "attr/2", "attr/1"].sort
               
          stub(fake_index).arity { 2 }
          query.send(:range_cache_keys, fake_index, [["attr", 1..12]]).last.sort.should == 
              ["attr/1100", "attr/10**", "attr/1**", "attr/1*", "attr/1"].sort
        end
                
        it 'creates keys from ranges correctly' do
          query = Query::Select.new(nil, nil, nil)
          query.send(:key_from_range, arity = 2, 4..7).should == "1**"
          query.send(:key_from_range, arity = 2, 0..15).should == "****"
          query.send(:key_from_range, arity = 10, 60..69).should == "6*"
        end
      end
      
      describe 'when the index supports ranges' do
        it 'does not create a bogus cache entry for id' do
          fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
          fable2 = Fable.create!(:author => 'John', :num_pages => '7')
          fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
          Fable.find(:all, :conditions => { :id => (fable1.id..fable3.id) })
          Story.get("id/2..3").should be_nil
        end
        
        it 'non-range conditions are not broken' do
          fable = Fable.create!(:author => 'Bob', :num_pages => '8')
          Fable.find(:all, :conditions => { :id => fable.id }).should == [fable]
        end
                
        describe 'when the range cache is prepopulated' do
          it 'uses the range cache' do
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            mock(Fable.connection).execute.never
            Fable.find(:all, :conditions => { :num_pages => 6..8 })
          end
          
          it 'uses the range cache for collections of items' do
            with_arity(4) do
              fables = (0..64).to_a.collect { |i| Fable.create!(:num_pages => i) }
              Fable.find(:all, :conditions => { :num_pages => 0..64 })
              mock(Fable.connection).execute.never
              Fable.find(:all, :conditions => { :num_pages => 0..64 })
            end
          end
        end
        
        describe 'when the range cache is empty' do
          it 'populates the range cache' do
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            $memcache.flush_all
            Fable.find(:all, :conditions => { :num_pages => (6..8) })            
            Fable.get("num_pages/6").data.should == [fable1.id]
            Fable.get("num_pages/7").data.should == [fable2.id]
            Fable.get("num_pages/8").data.should == [fable3.id]
          end
          
          it 'does not populate unnecessary subkeys' do
            fables = (0..10).to_a.collect { |i| Fable.create!(:num_pages => i) }
            $memcache.flush_all
            Fable.find(:all, :conditions => { :num_pages => (0..10) })
            Fable.get("num_pages/0").should be_nil
            Fable.get("num_pages/9").should be_nil
          end
          
          it 'does not populate subkeys using different tree aritys' do
            with_arity(2) do 
              fables = (5..11).to_a.collect { |i| Fable.create!(:num_pages => i) }
              $memcache.flush_all
              Fable.find(:all, :conditions => { :num_pages => (5..11) })
              Fable.get("num_pages/101").data.should == [fables[0].id]
              Fable.get("num_pages/11*").data.sort.should == fables[1..2].collect { |f| f.id }
              Fable.get("num_pages/1001").should be_nil
            end
          end
        end
        
        describe 'when the range cache is partially populated' do
          it 'fills the missing entries in the range cache' do
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            $memcache.flush_all
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            Fable.find(:all, :conditions => { :num_pages => (6..8) })
            Fable.get("num_pages/7").data.should == [fable2.id]
          end
          
          it 'populates keys for partial collections of items' do
            fables = (9..12).to_a.collect { |i| Fable.create!(:num_pages => i) }
            $memcache.flush_all
            fables += ((13..20).to_a.collect { |i| Fable.create!(:num_pages => i) })
            Fable.get("num_pages/20").data.should == [fables.last.id]
            Fable.find(:all, :conditions => { :num_pages => 9..20 })
            Fable.get("num_pages/9").data.should == [fables.first.id]
            Fable.get("num_pages/1*").data.should == fables[1..10].collect { |f| f.id }
          end
          
          it 'sets parent pointers in the left branch' do
            with_arity(4) do
              fable = Fable.create!(:num_pages => 0)
              Fable.find(:all, :conditions => { :num_pages => 0..63 })
              Fable.get("num_pages/***").data.should == [fable.id]
              Fable.get("num_pages/***").parent.should be_nil
              Fable.get("num_pages/**").data.should be_nil
              Fable.get("num_pages/**").parent.should == "num_pages/***"
              Fable.get("num_pages/*").data.should be_nil
              Fable.get("num_pages/*").parent.should == "num_pages/**"
              Fable.get("num_pages/0").data.should == [fable.id]
              Fable.get("num_pages/0").parent.should be_nil
            end
          end

          it 'sets intermediate left branch parent pointers' do
            with_arity(4) do
              fable = Fable.create!(:num_pages => 0)
              Fable.find(:all, :conditions => { :num_pages => 0..63 })
              Fable.find(:all, :conditions => { :num_pages => 0..3 })
              Fable.get("num_pages/***").data.should == [fable.id]
              Fable.get("num_pages/**").data.should be_nil
              Fable.get("num_pages/*").data.should == [fable.id]
            end
          end   
        end
      end
    end
  end
end