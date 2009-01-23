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
        it 'writes records into the regurlar cache at primary key' do
          fable = Fable.create!(:author => 'Sam', :num_pages => '123')
          Fable.get("id/#{fable.id}").should == [fable]
        end
        
        it 'writes records into the range cache at the correct keys' do
          fable = Fable.create!(:author => 'Sam', :num_pages => '6')
          Fable.get("num_pages/6").should == [fable.id]
        end
        
        it 'does not write individual objects into the range cache for empty collections' do
          fable = Fable.create!(:author => 'Sam', :num_pages => '106')
          Fable.get("num_pages/1**").should == nil
          Fable.get("num_pages/10*").should == nil
          Fable.get("num_pages/106").should == [fable.id]
        end
        
        it 'does write individual objects into the range cache for populated collections' do
          Fable.set("num_pages/1**", [99])
          fable = Fable.create!(:author => 'Sam', :num_pages => '106')
          Fable.get("num_pages/1**").sort.should == [99, fable.id].sort
          Fable.get("num_pages/10*").should == nil
          Fable.get("num_pages/106").should == [fable.id]
        end
        
        it 'appends records to range cache when keys match' do
          fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
          fable2 = Fable.create!(:author => 'Kumar', :num_pages => '6')
          Fable.get("num_pages/6").should == [fable1.id, fable2.id]
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
          Fable.set("num_pages/12*", [99])
          fable = Fable.create!(:author => 'Sam', :num_pages => '123')
          Fable.get("num_pages/12*").should == [fable.id, 99]
          Fable.get("num_pages/123").should == [fable.id]
          fable.update_attributes(:num_pages => '145')
          Fable.get("num_pages/12*").should == [99]
          Fable.get("num_pages/123").should == []
        end
        
        it 'adds objects to the range cache at the new keys' do
          Fable.set("num_pages/14*", [99])
          fable = Fable.create!(:author => 'Sam', :num_pages => '123')
          fable.update_attributes(:num_pages => '145')
          Fable.get("num_pages/14*").should == [fable.id, 99]
          Fable.get("num_pages/145").should == [fable.id]
        end
      end
    end
    
    describe '#destroy' do
      describe 'when the index supports ranges' do
        it 'removes objects from the range cache' do
          Fable.set("num_pages/1**", [99])
          Fable.set("num_pages/14*", [100])
          fable1 = Fable.create!(:author => 'Sam', :num_pages => '123')
          fable2 = Fable.create!(:author => 'Linda', :num_pages => '145')
          fable1.destroy
          Fable.get("num_pages/1**").should == [fable2.id, 99]
          Fable.get("num_pages/12*").should == []
          Fable.get("num_pages/123").should == []
          Fable.get("num_pages/14*").should == [fable2.id, 100]
          Fable.get("num_pages/145").should == [fable2.id]
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
      
      describe 'when the index supports ranges' do
        it 'does not create a bogus cache entry for id' do
          fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
          fable2 = Fable.create!(:author => 'John', :num_pages => '7')
          fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
          Fable.find(:all, :conditions => { :id => (fable1.id..fable3.id) })
          Story.get("id/2..3").should be_nil
        end
        
        it 'does not break non-range conditions' do
          fable = Fable.create!(:author => 'Bob', :num_pages => '8')
          Fable.find(:all, :conditions => { :id => fable.id }).should == [fable]
        end
        
        it 'calculates range cache keys correctly' do
          query = Query::Select.new(nil, nil, nil)
          query.send(:range_cache_keys, [["attr", 0..999]]).should == ["attr/***"]
          query.send(:range_cache_keys, [["attr", 0..400]]).sort.should ==
              ["attr/400", "attr/3**", "attr/2**", "attr/1**", "attr/**"].sort
          query.send(:range_cache_keys, [["attr", 1..99]]).sort.should ==
              ["attr/9*", "attr/8*", "attr/7*", "attr/6*", "attr/5*", "attr/4*", 
               "attr/3*", "attr/2*", "attr/1*", "attr/9", "attr/8", "attr/7", "attr/6", 
               "attr/5", "attr/4", "attr/3", "attr/2", "attr/1"].sort
        end
        
        describe 'when the range cache is prepopulated' do
          it 'uses the range cache' do
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            # mock(Fable.connection).execute.never
            Fable.find(:all, :conditions => { :num_pages => 1..400 })
          end
        end
        
        describe 'when the range cache is empty' do
          it 'populates the range cache' do
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            $memcache.flush_all
            Fable.find(:all, :conditions => { :num_pages => (6..8) })
            Fable.get("num_pages/6").should == [fable1.id]
            Fable.get("num_pages/7").should == [fable2.id]
            Fable.get("num_pages/8").should == [fable3.id]
          end
        end
        
        describe 'when the range cache is partially populated' do
          it 'fills the missing entries in the range cache' do
            fable2 = Fable.create!(:author => 'John', :num_pages => '7')
            $memcache.flush_all            
            fable1 = Fable.create!(:author => 'Sam', :num_pages => '6')
            fable3 = Fable.create!(:author => 'Bob', :num_pages => '8')
            Fable.find(:all, :conditions => { :num_pages => (6..8) })
            Fable.get("num_pages/7").should == [fable2.id]
          end
        end
      end
    end
  end
end