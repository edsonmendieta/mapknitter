require 'open3'
class Map < ActiveRecord::Base
  before_validation :update_name
  validates_presence_of :name,:author,:lat,:lon
  validates_uniqueness_of :name
  validates_presence_of :location, :message => ' cannot be found. Try entering a latitude and longitude if this problem persists.'
  validates_format_of       :name,
                            :with => /[a-zA-Z0-9_-]/,  
                            :message => " must not include spaces and must be alphanumeric, as it'll be used in the URL of your map, like: http://cartagen.org/maps/your-map-name. You may use dashes and underscores.",
                            :on => :create                  
  has_many :warpables
  has_one :export

  # Hash the password before saving the record
  def before_create
    self.password = Password::update(self.password) if self.password != ""
  end

  def update_name
    self.name = self.name.gsub(/\W/, '-').downcase
  end

  def private
    self.password != ""
  end

  def self.bbox(minlat,minlon,maxlat,maxlon)
	Map.find :all, :conditions => ['lat > ? AND lat < ? AND lon > ? AND lon < ?',minlat,maxlat,minlon,maxlon]
  end

  def self.authors
    authors = []
    maps_authors = Map.find :all, :group => "maps.author", :conditions => ['password = "" AND archived = false']
    maps_authors.each do |map|
      authors << map.author
    end
    authors
  end

  def self.new_maps
    self.find(:all, :order => "created_at DESC", :limit => 12, :conditions => ['password = "" AND archived = false'])
  end

  def validate
    self.name != 'untitled'
    self.name = self.name.gsub(' ','-')
    self.lat >= -90 && self.lat <= 90 && self.lon >= -180 && self.lat <= 180
  end

  def warpables
    Warpable.find :all, :conditions => {:map_id => self.id, :deleted => false} 
  end

  def nodes
    nodes = {}
    self.warpables.each do |warpable|
      if warpable.nodes != ''
        w_nodes = []
        warpable.nodes.split(',').each do |node|
          node_obj = Node.find(node)
          w_nodes << [node_obj.lon,node_obj.lat]
        end
        nodes[warpable.id.to_s] = w_nodes
      end
      nodes[warpable.id.to_s] ||= 'none'
    end
    nodes
  end

  # Finds any warpables which have not been placed on the map manually, and deletes them.
  # Also returns remaining valid warpables.
  def flush_unplaced_warpables
    more_than_one_unplaced = false
    self.warpables.each do |warpable|
      if (warpable.nodes == "" && warpable.created_at == warpable.updated_at)
	# delete warpables which have not been placed and are older than 1 hour:
	warpable.delete if DateTime.now-5.minutes > warpable.created_at || more_than_one_unplaced
        more_than_one_unplaced = true
      end
    end
    warpables
  end 

  def average_scale
	# determine optimal zoom level
	puts '> calculating scale'
	pxperms = []
	self.warpables.each do |warpable|
		pxperms << 100.00/warpable.cm_per_pixel unless warpable.width.nil?
	end
	average = (pxperms.inject {|sum, n| sum + n })/pxperms.length
	puts 'average scale = '+average.to_s+' px/m'
        average
  end

  def best_cm_per_pixel
    hist = self.images_histogram
    scores = []
    (0..(hist.length-1)).each do |i|
      scores[i] = 0
      scores[i] += hist[i-3] if i > 3
      scores[i] += hist[i-2] if i > 2
      scores[i] += hist[i-1] if i > 1
      scores[i] += hist[i]
      scores[i] += hist[i+1] if i < hist.length - 2
      scores[i] += hist[i+2] if i < hist.length - 3
      scores[i] += hist[i+3] if i < hist.length - 4
    end
    highest = 0
    scores.each_with_index do |s,i|
      highest = i if s > scores[highest]
    end
    highest
  end

  def average_cm_per_pixel
	scales = []
	count = 0
	average = 0
	self.warpables.each do |warpable|
		unless warpable.width.nil?
			count += 1
			res = warpable.cm_per_pixel 
			scales << res unless res == nil
		end
	end
	average = (scales.inject {|sum, n| sum + n })/count if scales
	puts 'average scale = '+average.to_s+' cm/px'
        average
  end

  def images_histogram
	hist = []
	self.warpables.each do |warpable|
		res = warpable.cm_per_pixel.to_i
		hist[res] = 0 if hist[res] == nil 
		hist[res] += 1
	end
	(0..hist.length-1).each do |bin|
		hist[bin] = 0 if hist[bin] == nil
	end
	hist
  end

  def grouped_images_histogram(binsize)
	hist = []
	self.warpables.each do |warpable|
		res = warpable.cm_per_pixel
		if res != nil
			res = (warpable.cm_per_pixel/(0.001+binsize)).to_i
			hist[res] = 0 if hist[res] == nil 
			hist[res] += 1
		end
	end
	(0..hist.length-1).each do |bin|
		hist[bin] = 0 if hist[bin] == nil
	end
	hist
  end

  # distort all warpables, returns upper left corner coords in x,y
  def distort_warpables(scale)
	export = Export.find_by_map_id(self.id)
	puts '> generating geotiffs of each warpable in GDAL'
	lowest_x=0
	lowest_y=0
	warpable_coords = []
	warpables = self.warpables
	current = 0
	warpables.each do |warpable|
		current += 1
		export.status = 'warping '+current.to_s+' of '+warpables.length.to_s
		puts 'warping '+current.to_s+' of '+warpables.length.to_s
		export.save
		my_warpable_coords = warpable.generate_perspectival_distort(scale,self.name)
		puts '- '+my_warpable_coords.to_s
		warpable_coords << my_warpable_coords
		lowest_x = my_warpable_coords.first if (my_warpable_coords.first < lowest_x || lowest_x == 0)
		lowest_y = my_warpable_coords.last if (my_warpable_coords.last < lowest_y || lowest_y == 0)
	end
	[lowest_x,lowest_y,warpable_coords]
  end

  def generate_composite_tiff(coords,origin)
        directory = "public/warps/"+self.name+"/"
        geotiff_location = directory+self.name+'-geo-merge.tif'
	geotiffs = ''
	minlat = nil
	minlon = nil
	maxlat = nil
	maxlon = nil
	self.warpables.each do |warpable|
		warpable.nodes_array.each do |n|
			minlat = n.lat if minlat == nil || n.lat < minlat
			minlon = n.lon if minlon == nil || n.lon < minlon
			maxlat = n.lat if maxlat == nil || n.lat > maxlat
			maxlon = n.lon if maxlon == nil || n.lon > maxlon
		end
	end
	first = true
	self.warpables.each do |warpable|
        	geotiffs += ' '+directory+warpable.id.to_s+'-geo.tif'
		if first
			gdalwarp = "gdalwarp -te "+minlon.to_s+" "+minlat.to_s+" "+maxlon.to_s+" "+maxlat.to_s+" "+directory+warpable.id.to_s+'-geo.tif '+directory+self.name+'-geo.tif'
			first = false
		else
			gdalwarp = "gdalwarp "+directory+warpable.id.to_s+'-geo.tif '+directory+self.name+'-geo.tif'
		end
		puts gdalwarp
		system(Gdal.ulimit+gdalwarp)
        end
	gdal_merge = "gdal_merge.py -o "+geotiff_location+geotiffs
	#gdal_merge = "gdal_merge.py -v -n 0 -o "+geotiff_location+geotiffs
	#gdal_merge = "gdal_merge.py -v -n 0 -init 255 -o "+geotiff_location+geotiffs
	puts gdal_merge
	system(Gdal.ulimit+gdal_merge)
	geotiff_location
  end
  
  # generates a tileset at RAILS_ROOT/public/tms/<map_name>/
  def generate_tiles
    google_api_key = APP_CONFIG["google_maps_api_key"]
    gdal2tiles = 'gdal2tiles.py -k -t "'+self.name+'" -g "'+google_api_key+'" '+RAILS_ROOT+'/public/warps/'+self.name+'/'+self.name+'-geo.tif '+RAILS_ROOT+'/public/tms/'+self.name+"/"
#    puts gdal2tiles
#    puts system('which gdal2tiles.py')
    system(Gdal.ulimit+gdal2tiles)
  end

  # zips up tiles at RAILS_ROOT/public/tms/<map_name>.zip
  def zip_tiles
      rmzip = 'cd public/tms/ && rm '+self.name+'.zip && cd ../../'
      system(Gdal.ulimit+rmzip)
    zip = 'cd public/tms/ && zip -rq '+self.name+'.zip '+self.name+'/ && cd ../../'
#    puts zip 
#    puts system('which gdal2tiles.py')
    system(Gdal.ulimit+zip)
  end
 
 
  def generate_jpg
	imageMagick = 'convert -background white -flatten '+RAILS_ROOT+'/public/warps/'+self.name+'/'+self.name+'-geo.tif '+RAILS_ROOT+'/public/warps/'+self.name+'/'+self.name+'.jpg'
	system(Gdal.ulimit+imageMagick)
  end
 
  def before_save
    self.styles = 'body: {
	lineWidth: 0,
	menu: {
		"Edit GSS": Cartagen.show_gss_editor,
		"Download Image": Cartagen.redirect_to_image,
		"Download Data": Interface.download_bbox
	}
},
node: {
	fillStyle: "#ddd",
	strokeStyle: "#090",
	lineWidth: 0,
	radius: 1,
	opacity: 0.8
},
way: {
	strokeStyle: "#ccc",
	lineWidth: 3,
	opacity: 0.8,
	menu: {
		"Toggle Transparency": function() {
			if (this._transparency_active) {
				this.opacity = 1
				this._transparency_active = false
			}
			else {
				this.opacity = 0.2
				this._transparency_active = true
			}
		}
	}
},
island: {
	strokeStyle: "#24a",
	lineWidth: 4,
	pattern: "/images/brown-paper.jpg"
},
relation: {
	fillStyle: "#57d",
	strokeStyle: "#24a",
	lineWidth: 4,
	pattern: "/images/pattern-water.gif"
},
administrative: {
	lineWidth: 50,
	strokeStyle: "#D45023",
	fillStyle: "rgba(0,0,0,0)",
},
leisure: {
	fillStyle: "#2a2",
	lineWidth: 3,
	strokeStyle: "#181"
},
area: {
	lineWidth: 8,
	strokeStyle: "#4C6ACB",
	fillStyle: "rgba(0,0,0,0)",
	opacity: 0.4,
	fontColor: "#444",
},
park: {
	fillStyle: "#2a2",
	lineWidth: 3,
	strokeStyle: "#181",
	fontSize: 12,
	text: function() { return this.tags.get("name") },
	fontRotation: "fixed",
	opacity: 1
},
waterway: {
	fillStyle: "#57d",
	strokeStyle: "#24a",
	lineWidth: 4,
	pattern: "/images/pattern-water.gif"
},
water: {
	strokeStyle: "#24a",
	lineWidth: 4,
	pattern: "/images/pattern-water.gif"
},
highway: {
	strokeStyle: "white",
	lineWidth: 6,
	outlineWidth: 3,
	outlineColor: "white",
	fontColor: "#333",
	fontBackground: "white",
	fontScale: "fixed",
	text: function() { return this.tags.get("name") }
},
primary: {
	strokeStyle: "#d44",
	lineWidth: function() {
		if (this.tags.get("width")) return parseInt(this.tags.get("width"))*0.8
		else return 10
	}
},
secondary: {
	strokeStyle: "#d44",
	lineWidth: function() {
		if (this.tags.get("width")) return parseInt(this.tags.get("width"))*0.8
		else return 7
	}
},
footway: {
	strokeStyle: "#842",
	lineWidth: function() {
		if (this.tags.get("width")) return parseInt(this.tags.get("width"))*0.8
		else return 3
	}
},
pedestrian: {
	strokeStyle: "#842",
	fontBackground: "rgba(1,1,1,0)",
	fontColor: "#444",
	lineWidth: function() {
		if (this.tags.get("width")) return parseInt(this.tags.get("width"))*0.8
		else return 3
	}
},
parkchange: {
	glow: "yellow"
},
building: {
	opacity: 1,
	lineWidth: 0.001,
	fillStyle: "#444",
	text: function() { return this.tags.get("name") },
	hover: {
		fillStyle: "#222"
	},
	mouseDown: {
		lineWidth: 18,
		strokeStyle: "red"
	},
	menu: {
		"Search on Google": function() {
			if (this.tags.get("name")) {
				window.open("http://google.com/search?q=" + this.tags.get("name"), "_blank")
			}
			else {
				alert("Sorry! The name of this building is unknown.")
			}
		},
		"Search on Wikipedia": function() {
			if (this.tags.get("name")) {
				window.open("http://en.wikipedia.org/wiki/Special:Search?go=Go&search=" + this.tags.get("name"), "_blank")
			}
			else {
				alert("Sorry! The name of this building is unknown.")
			}
		}
	}
},
landuse: {
	fillStyle: "#ddd"
},
rail: {
	lineWidth: 4,
	strokeStyle: "purple"
},
debug: {
	way: {
		menu: {
			"Inspect": function() {$l(this)}
		}
	}
}'
  end
  
  def after_create
    puts 'saving Map'
    if last = Map.find_by_name(self.name,:order => "version DESC")
      self.version = last.version + 1
    end
  end

end
