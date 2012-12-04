package test;
import haxe.macro.Expr;
import hxsl.Unserialize;
import hxsl.Serialize;
#if macro
import haxe.macro.Context;
#end

class Main {
	
	static var COUNT = 0;

	#if macro
	static function agalToString( c : format.agal.Data ) {
		var lines = [];
		for( o in c.code )
			lines.push(format.agal.Tools.opStr(o));
		return lines.join("\n");
	}
	
	static function agalToBytes( c : format.agal.Data ) {
		var o = new haxe.io.BytesOutput();
		new format.agal.Writer(o).write(c);
		return o.getBytes();
	}
	
	static function compileShader( shader : Expr, params : {} ) {
		var p = new hxsl.Parser().parse(shader);
		var c = new hxsl.Compiler();
		var warnings = [];
		// warning as errors
		c.warn = function(msg, p) warnings.push({ msg : msg, p : p });
		var data = c.compile(p);
		data = new hxsl.RuntimeCompiler().compile(data, params);
		var vert = new hxsl.AgalCompiler().compile(data.vertex);
		var frag = new hxsl.AgalCompiler().compile(data.fragment);
		var vexpr = { expr : EConst(CString(haxe.Serializer.run(agalToBytes(vert)))), pos : shader.pos };
		var fexpr = { expr : EConst(CString(haxe.Serializer.run(agalToBytes(frag)))), pos : shader.pos };
		var chk = macro testRuntimeShader($vexpr,$fexpr);
		return { str : agalToString(vert) + "\n\n" + agalToString(frag), warn : warnings, chk : chk };
	}
	#end
	
	@:macro static function test( shader : Expr, out : String, ?params : { } ) {
		var s = null;
		var consts = [];
		try {
			s = compileShader(shader, params);
		} catch( e : hxsl.Data.Error ) {
			if( e.message == out )
				return macro null;
			Context.error(e.message, e.pos);
		}
		if( s.str == null )
			return macro null;
		var out = StringTools.trim(out.split("\r\n").join("\n").split("\t").join(""));
		if( s.str != out ) {
			var msg = ["Wrong AGAL output :"];
			var req = out.split("\n");
			var asm = s.str.split("\n");
			for( i in 0...(req.length > asm.length ? req.length : asm.length) ) {
				var r = req[i], a = asm[i];
				if( r == null ) r = "";
				if( a == null ) a = "";
				if( r == "" && a == "" )
					msg.push("");
				else
					msg.push("    "+StringTools.rpad(a, " ", 30) + (r == a ? "is          " : "should be    ") + r);
			}
			Context.error(msg.join("\n"), shader.pos);
		} else if( s.warn.length > 0 ) {
			for( w in s.warn )
				Context.warning(w.msg, w.p);
			Context.error("Unexpected warnings", shader.pos);
		}
		return s.chk;
	}
	
	@:macro static function error( shader : Expr, msg : String, ?params : { } ) {
		try {
			compileShader(shader, params);
			Context.error("Shader compilation should give an error", shader.pos);
		} catch( e : hxsl.Data.Error ) {
			if( e.message != msg ) Context.error("Unexpected error : " + e.message, e.pos);
		}
		return { expr : EBlock([]), pos : shader.pos };
	}
	
	@:macro static function warning( shader : Expr, msg : String, ?params : { } ) {
		try {
			var r = compileShader(shader, params);
			if( r.warn.length == 0 )
				Context.error("No warning was printed", shader.pos);
			else if( r.warn.length > 1 )
				Context.error("Too many warning were printed [" + r.warn + "]", shader.pos);
			else if( r.warn[0].msg != msg )
				Context.error("Unexpected warning : " + r.warn[0].msg, r.warn[0].p);
		} catch( e : hxsl.Data.Error ) {
			Context.error("Unexpected error : " + e.message, e.pos);
		}
		return { expr : EBlock([]), pos : shader.pos };
	}
	
	#if !macro

	static function stringToBytes( str : String ) {
		var bytes : haxe.io.Bytes = haxe.Unserializer.run(str);
		var bytes = bytes.getData();
		bytes.endian = flash.utils.Endian.LITTLE_ENDIAN;
		return bytes;
	}
	
	static function testRuntimeShader( vertex : String, fragment : String ) {
		var p = ctx.createProgram();
		p.upload(stringToBytes(vertex), stringToBytes(fragment));
		p.dispose();
		COUNT++;
	}

	static function checkShaders() {
		
		// basic shader
		test({
			var input : {
				pos : Float3,
				uv : Float2,
			};
			var tuv : Float2;
			function vertex( mproj : Matrix ) {
				var tmp = pos.xyzw * mproj;
				out = tmp;
				tuv = uv;
			}
			function fragment( tex : Texture ) {
				out = tex.get(tuv);
			}
		},"
			m44 t0, a0.xyzw, c0
			mov out, t0
			mov v0, a1

			tex t0, tex0[v0.xy]
			mov out, t0
		");
		
		// check that we can read all from a varying
		test( {
			var input : {
				pos : Float3,
			};
			var color : Float3;
			function vertex( mpos : M44, mproj : M44 ) {
				out = pos.xyzw * mpos * mproj;
				color = pos;
			}
			function fragment() {
				out = color.xyzw;
			}
		},"
			m44 t0, a0.xyzw, c0
			dp4 out.x, t0, c4
			dp4 out.y, t0, c5
			dp4 out.z, t0, c6
			dp4 out.w, t0, c7
			mov v0, a0
			
			mov out, v0.xyzw
		");
		
		// let's try a const
		test( {
			var pos : Input<Float4>;
			function vertex( mpos : Matrix ) {
				out = (mpos == null) ? pos : pos * mpos;
			}
			function fragment() { out = [1, 2, 3, 4]; }
		},"
			mov out, a0
			
			mov out, c0.xyzw
		");
		
		test( {
			function vertex( a : Float4 ) {
				out = a;
			}
			function fragment( a : Float4 ) {
				out = a;
			}
		},"Duplicate variable a");

		// invalid const usage
		error( {
			var pos : Input<Float4>;
			function vertex() {
				out = (pos == null) ? pos : pos;
			}
			function fragment() { out = [1, 2, 3, 4]; }
		},"Only constants can be compared to null");

		error({
		},"Missing vertex function");
		
		error( {
			function vertex() {
			}
		},"Missing fragment function");

		error( {
			var input : {
				pos : Float3,
			};
			function vertex() {
			}
			function fragment() {
				out = pos.xyzw;
			}
		},"Output is not written by vertex shader");
		
		error( {
			var input : {
				pos : Float3,
			};
			function vertex() {
				out = pos.xyzw;
			}
			function fragment() {
			}
		},"Output is not written by fragment shader");

		
		error( {
			function vertex(tmp:Float4) {
				tmp + tmp = tmp;
			}
			function fragment() {
			}
		},"Invalid assign");
		
		error( {
			var input : {
				pos : Float3,
			};
			function vertex() {
				out = xpos.xyzw;
			}
			function fragment() {
			}
		},"Unknown variable 'xpos'");
		
		warning( {
			var v : Input<Float4>;
			var unused : Float;
			function vertex() {
				out = v;
			}
			function fragment() {
				out = v;
			}
		},"Parameter 'unused' not used");
		
		test( {
			function vertex() {
				if( true ) {
					out.xyz = [1,1,1];
				} else {
					out = [1, 2, 3, 4];
				}
				out.w = 0;
			}
			function fragment() {
				out = [1, 2, 3, 4];
			}
		},"
			mov out.xyz, c0.xxx
			mov out.w, c0.y

			mov out, c0.xyzw
		");

		test( {
			function vertex() {
				out = [0, 0, 0, 0];
			}
			function fragment( a : Float4, b : Float4 ) {
				out = [a.x, a.y, b.x, b.y];
			}
		},"
			mov out, c0.xxxx
			
			mov t0.x, c0.x
			mov t0.y, c0.y
			mov t0.z, c1.x
			mov t0.w, c1.y
			mov out, t0
		");
		
		test( {
			var input : {
				pos : Float3,
				uv : Float2,
			};
			
			var tuv : Float2;
			
			var useMatrixPos : Bool;
			var uvScale : Const<Float2>;
			var uvDelta : Const<Float2>;
			
			function vertex( mpos : Matrix, mproj : Matrix ) {
				out = if( useMatrixPos ) (pos.xyzw * mpos) * mproj else pos.xyzw * mproj;
				var t = uv;
				if( uvScale != null ) t *= uvScale;
				if( uvDelta != null ) t += uvDelta;
				tuv = t;
			}
			
			function fragment( tex : Texture, killAlpha : Bool, colorDelta : Float4, colorMult : Float4, colorMatrix : M44 ) {
				var c = tex.get(tuv.xy);
				if( killAlpha ) kill(c.a - 0.001);
				if( colorDelta != null ) c += colorDelta;
				if( colorMult != null ) c = c * colorMult;
				if( colorMatrix != null ) c = c * colorMatrix;
				out = c;
			}
		},"
			m44 out, a0.xyzw, c0
			mov t0.xy, a1.xy
			mov v0.xy, t0.xy
			mov v0.zw, c0.xx
			
			tex t0, tex0[v0.xy]
			mov out, t0
		");

		test( {
			var input : {
				pos : Float3,
				uv : Float2,
			};
			
			var tuv : Float2;
			
			var useMatrixPos : Bool;
			var uvScale : Const<Float2>;
			var uvDelta : Const<Float2>;
			
			function vertex( mpos : Matrix, mproj : Matrix ) {
				out = if( useMatrixPos ) (pos.xyzw * mpos) * mproj else pos.xyzw * mproj;
				var t = uv;
				if( uvScale != null ) t *= uvScale;
				if( uvDelta != null ) t += uvDelta;
				tuv = t;
			}
			
			function fragment( tex : Texture, killAlpha : Bool, colorDelta : Float4, colorMult : Float4, colorMatrix : M44 ) {
				var c = tex.get(tuv.xy);
				if( killAlpha ) kill(c.a - 0.001);
				if( colorDelta != null ) c += colorDelta;
				if( colorMult != null ) c = c * colorMult;
				if( colorMatrix != null ) c = c * colorMatrix;
				out = c;
			}
		},"
			m44 out, a0.xyzw, c1
			mov t0.xy, a1.xy
			mul t1.xy, t0.xy, c0.xy
			mov v0.xy, t1.xy
			mov v0.zw, c0.xx
			
			tex t0, tex0[v0.xy]
			sub t1.w, t0.w, c0.x
			kil t1.w
			mul t2, t0, c0
			mov out, t2
		", { uvScale : 0, killAlpha : true, colorMult : 0 });
		
		trace(COUNT+" shaders checked");
	}
	
	static var ctx : flash.display3D.Context3D;
		
	static function main() {
		var stage = flash.Lib.current.stage.stage3Ds[0];
		stage.addEventListener(flash.events.Event.CONTEXT3D_CREATE, function(_) {
			ctx = stage.context3D;
			checkShaders();
		});
		stage.requestContext3D();
	}
	#end
	
}