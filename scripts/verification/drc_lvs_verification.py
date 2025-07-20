#!/usr/bin/env python3
"""
AxiomaCore-328 Physical Verification Suite
Automated DRC, LVS, and PEX verification for tape-out
"""

import os
import sys
import subprocess
import argparse
import json
from pathlib import Path
import time

class AxiomaVerificationSuite:
    def __init__(self, design_dir, run_tag="axioma_phase9_tapeout"):
        self.design_dir = Path(design_dir)
        self.run_tag = run_tag
        self.results_dir = self.design_dir / "runs" / run_tag / "results"
        self.reports_dir = self.design_dir / "runs" / run_tag / "reports"
        self.verification_results = {}
        
    def log(self, message, level="INFO"):
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{timestamp}] {level}: {message}")
        
    def run_magic_drc(self):
        """Run Magic DRC verification"""
        self.log("Starting Magic DRC verification...")
        
        gds_file = self.results_dir / "final" / "gds" / "axioma_cpu_v5.gds"
        if not gds_file.exists():
            self.log("ERROR: GDSII file not found", "ERROR")
            return False
            
        try:
            # Magic DRC script
            magic_script = f"""
            tech load sky130A
            gds read {gds_file}
            load axioma_cpu_v5
            select top cell
            drc check
            drc catchup
            drc count
            set drc_count [drc list count total]
            puts "DRC violations: $drc_count"
            if {{$drc_count > 0}} {{
                drc list
                drc why
            }}
            quit -noprompt
            """
            
            with open("/tmp/magic_drc.tcl", "w") as f:
                f.write(magic_script)
                
            result = subprocess.run([
                "magic", "-dnull", "-noconsole", "-T", "sky130A", 
                "/tmp/magic_drc.tcl"
            ], capture_output=True, text=True)
            
            if "DRC violations: 0" in result.stdout:
                self.log("✅ Magic DRC: CLEAN")
                self.verification_results["magic_drc"] = "PASS"
                return True
            else:
                violations = self._extract_drc_count(result.stdout)
                self.log(f"❌ Magic DRC: {violations} violations", "ERROR")
                self.verification_results["magic_drc"] = f"FAIL ({violations} violations)"
                return False
                
        except Exception as e:
            self.log(f"Magic DRC failed: {e}", "ERROR")
            self.verification_results["magic_drc"] = "ERROR"
            return False
            
    def run_klayout_drc(self):
        """Run KLayout DRC verification"""
        self.log("Starting KLayout DRC verification...")
        
        gds_file = self.results_dir / "final" / "gds" / "axioma_cpu_v5.gds"
        
        try:
            # KLayout DRC script
            klayout_script = f"""
            require 'drc/drc'
            
            report("DRC Report for AxiomaCore-328")
            
            target_layout = Layout::new
            target_layout.read("{gds_file}")
            target_cell = target_layout.top_cell
            
            # Load Sky130 DRC rules
            load("sky130A.drc")
            
            # Run DRC
            drc_db = RDB::new("axioma_drc_results")
            drc_results = run_drc(target_layout, target_cell, drc_db)
            
            puts "KLayout DRC violations: #{drc_results.size}"
            
            if drc_results.size > 0
                drc_results.each_with_index do |violation, i|
                    puts "Violation #{i+1}: #{violation.description}"
                end
            end
            
            # Save report
            drc_db.save("{self.reports_dir}/klayout_drc_report.xml")
            """
            
            with open("/tmp/klayout_drc.rb", "w") as f:
                f.write(klayout_script)
                
            result = subprocess.run([
                "klayout", "-b", "-r", "/tmp/klayout_drc.rb"
            ], capture_output=True, text=True)
            
            if "KLayout DRC violations: 0" in result.stdout:
                self.log("✅ KLayout DRC: CLEAN")
                self.verification_results["klayout_drc"] = "PASS"
                return True
            else:
                violations = self._extract_klayout_drc_count(result.stdout)
                self.log(f"❌ KLayout DRC: {violations} violations", "ERROR")
                self.verification_results["klayout_drc"] = f"FAIL ({violations} violations)"
                return False
                
        except Exception as e:
            self.log(f"KLayout DRC failed: {e}", "ERROR")
            self.verification_results["klayout_drc"] = "ERROR"
            return False
            
    def run_netgen_lvs(self):
        """Run Netgen LVS verification"""
        self.log("Starting Netgen LVS verification...")
        
        # Get required files
        gds_file = self.results_dir / "final" / "gds" / "axioma_cpu_v5.gds"
        netlist_file = self.results_dir / "final" / "verilog" / "gl" / "axioma_cpu_v5.nl.v"
        
        if not all([gds_file.exists(), netlist_file.exists()]):
            self.log("ERROR: Required files for LVS not found", "ERROR")
            return False
            
        try:
            # Netgen LVS script
            netgen_script = f"""
            # AxiomaCore-328 LVS comparison
            readlib sky130A
            
            # Read layout from GDSII
            read spice {gds_file}
            flatten axioma_cpu_v5_layout
            
            # Read netlist
            read spice {netlist_file}
            flatten axioma_cpu_v5_netlist
            
            # Run LVS comparison
            compare axioma_cpu_v5_layout axioma_cpu_v5_netlist
            
            # Generate report
            summary
            
            quit
            """
            
            with open("/tmp/netgen_lvs.tcl", "w") as f:
                f.write(netgen_script)
                
            result = subprocess.run([
                "netgen", "-batch", "source", "/tmp/netgen_lvs.tcl"
            ], capture_output=True, text=True)
            
            if "Circuits match" in result.stdout:
                self.log("✅ Netgen LVS: MATCH")
                self.verification_results["netgen_lvs"] = "PASS"
                return True
            else:
                self.log("❌ Netgen LVS: MISMATCH", "ERROR")
                self.verification_results["netgen_lvs"] = "FAIL"
                return False
                
        except Exception as e:
            self.log(f"Netgen LVS failed: {e}", "ERROR")
            self.verification_results["netgen_lvs"] = "ERROR"
            return False
            
    def run_parasitic_extraction(self):
        """Run parasitic extraction for timing analysis"""
        self.log("Starting parasitic extraction (PEX)...")
        
        gds_file = self.results_dir / "final" / "gds" / "axioma_cpu_v5.gds"
        
        try:
            # Magic parasitic extraction
            magic_pex_script = f"""
            tech load sky130A
            gds read {gds_file}
            load axioma_cpu_v5
            select top cell
            
            # Extract parasitic capacitances and resistances
            extract do local
            extract all
            ext2spice lvs
            ext2spice cthresh 0.01
            ext2spice rthresh 0.01
            ext2spice
            
            quit -noprompt
            """
            
            with open("/tmp/magic_pex.tcl", "w") as f:
                f.write(magic_pex_script)
                
            result = subprocess.run([
                "magic", "-dnull", "-noconsole", "-T", "sky130A",
                "/tmp/magic_pex.tcl"
            ], capture_output=True, text=True)
            
            # Check if SPICE file was generated
            spice_file = Path("axioma_cpu_v5.spice")
            if spice_file.exists():
                # Move to results directory
                target_spice = self.results_dir / "final" / "spice" / "axioma_cpu_v5_pex.spice"
                target_spice.parent.mkdir(parents=True, exist_ok=True)
                spice_file.rename(target_spice)
                
                self.log("✅ Parasitic extraction: SUCCESS")
                self.verification_results["parasitic_extraction"] = "PASS"
                return True
            else:
                self.log("❌ Parasitic extraction: FAILED", "ERROR")
                self.verification_results["parasitic_extraction"] = "FAIL"
                return False
                
        except Exception as e:
            self.log(f"Parasitic extraction failed: {e}", "ERROR")
            self.verification_results["parasitic_extraction"] = "ERROR"
            return False
            
    def run_timing_analysis(self):
        """Run post-layout timing analysis with extracted parasitics"""
        self.log("Starting post-layout timing analysis...")
        
        try:
            # OpenSTA timing analysis
            spice_file = self.results_dir / "final" / "spice" / "axioma_cpu_v5_pex.spice"
            sdc_file = self.design_dir / "config" / "constraints.sdc"
            
            if not spice_file.exists():
                self.log("WARNING: No extracted parasitics found, using pre-layout netlist")
                spice_file = self.results_dir / "final" / "verilog" / "gl" / "axioma_cpu_v5.nl.v"
                
            sta_script = f"""
            read_liberty $::env(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
            read_netlist {spice_file}
            link_design axioma_cpu_v5
            
            read_sdc {sdc_file}
            
            # Report timing
            report_checks -path_delay min_max -format full_clock_expanded
            report_worst_slack -min
            report_worst_slack -max
            report_tns
            report_wns
            
            # Check for violations
            set setup_slack [sta::worst_slack max]
            set hold_slack [sta::worst_slack min]
            
            puts "Setup slack: $setup_slack"
            puts "Hold slack: $hold_slack"
            
            if {{$setup_slack < 0}} {{
                puts "ERROR: Setup violations detected"
            }} else {{
                puts "Setup timing: PASS"
            }}
            
            if {{$hold_slack < 0}} {{
                puts "ERROR: Hold violations detected"  
            }} else {{
                puts "Hold timing: PASS"
            }}
            
            exit
            """
            
            with open("/tmp/sta_analysis.tcl", "w") as f:
                f.write(sta_script)
                
            result = subprocess.run([
                "sta", "/tmp/sta_analysis.tcl"
            ], capture_output=True, text=True)
            
            if "Setup timing: PASS" in result.stdout and "Hold timing: PASS" in result.stdout:
                self.log("✅ Timing analysis: PASS")
                self.verification_results["timing_analysis"] = "PASS"
                return True
            else:
                self.log("❌ Timing analysis: VIOLATIONS", "ERROR")
                self.verification_results["timing_analysis"] = "FAIL"
                return False
                
        except Exception as e:
            self.log(f"Timing analysis failed: {e}", "ERROR")
            self.verification_results["timing_analysis"] = "ERROR"
            return False
            
    def generate_verification_report(self):
        """Generate comprehensive verification report"""
        self.log("Generating verification report...")
        
        report_content = f"""
# AxiomaCore-328 Physical Verification Report
**Date:** {time.strftime("%Y-%m-%d %H:%M:%S")}
**Design:** axioma_cpu_v5 
**Run:** {self.run_tag}

## Verification Summary

| Check | Status | Details |
|-------|--------|---------|
| Magic DRC | {self.verification_results.get('magic_drc', 'NOT RUN')} | Design Rule Check |
| KLayout DRC | {self.verification_results.get('klayout_drc', 'NOT RUN')} | Alternative DRC |
| Netgen LVS | {self.verification_results.get('netgen_lvs', 'NOT RUN')} | Layout vs Schematic |
| Parasitic Extraction | {self.verification_results.get('parasitic_extraction', 'NOT RUN')} | RC Extraction |
| Timing Analysis | {self.verification_results.get('timing_analysis', 'NOT RUN')} | Post-layout timing |

## Tape-out Readiness

"""
        
        # Calculate overall status
        all_passed = all(status == "PASS" for status in self.verification_results.values() if status != "NOT RUN")
        
        if all_passed and len(self.verification_results) >= 4:
            report_content += "🎉 **STATUS: READY FOR TAPE-OUT** 🎉\n\n"
            report_content += "All physical verification checks have passed. AxiomaCore-328 is ready for fabrication.\n\n"
        else:
            report_content += "⚠️ **STATUS: NOT READY FOR TAPE-OUT** ⚠️\n\n"
            report_content += "Some verification checks failed or are incomplete. Review and fix issues before tape-out.\n\n"
            
        report_content += f"""
## Next Steps

1. **If READY:** Submit GDSII for fabrication
2. **If NOT READY:** Fix violations and re-run verification
3. **Generate test vectors** for first silicon validation
4. **Prepare packaging requirements** for assembled parts

## Files Generated

- GDSII: `{self.results_dir}/final/gds/axioma_cpu_v5.gds`
- LEF: `{self.results_dir}/final/lef/axioma_cpu_v5.lef` 
- Gate-level netlist: `{self.results_dir}/final/verilog/gl/axioma_cpu_v5.nl.v`
- Parasitic netlist: `{self.results_dir}/final/spice/axioma_cpu_v5_pex.spice`

---
*AxiomaCore-328 - World's First Complete Open Source AVR Microcontroller*
"""
        
        # Save report
        report_file = self.reports_dir / "verification_report.md"
        report_file.parent.mkdir(parents=True, exist_ok=True)
        
        with open(report_file, "w") as f:
            f.write(report_content)
            
        self.log(f"Verification report saved: {report_file}")
        
        # Also save JSON results
        json_file = self.reports_dir / "verification_results.json"
        with open(json_file, "w") as f:
            json.dump(self.verification_results, f, indent=2)
            
        return all_passed
        
    def _extract_drc_count(self, output):
        """Extract DRC violation count from Magic output"""
        for line in output.split('\n'):
            if 'DRC violations:' in line:
                try:
                    return int(line.split(':')[1].strip())
                except:
                    pass
        return "unknown"
        
    def _extract_klayout_drc_count(self, output):
        """Extract DRC violation count from KLayout output"""
        for line in output.split('\n'):
            if 'KLayout DRC violations:' in line:
                try:
                    return int(line.split(':')[1].strip())
                except:
                    pass
        return "unknown"

def main():
    parser = argparse.ArgumentParser(description="AxiomaCore-328 Physical Verification Suite")
    parser.add_argument("--design-dir", required=True, help="Design directory path")
    parser.add_argument("--run-tag", default="axioma_phase9_tapeout", help="OpenLane run tag")
    parser.add_argument("--skip-drc", action="store_true", help="Skip DRC checks")
    parser.add_argument("--skip-lvs", action="store_true", help="Skip LVS check") 
    parser.add_argument("--skip-pex", action="store_true", help="Skip parasitic extraction")
    parser.add_argument("--skip-timing", action="store_true", help="Skip timing analysis")
    
    args = parser.parse_args()
    
    verifier = AxiomaVerificationSuite(args.design_dir, args.run_tag)
    
    verifier.log("Starting AxiomaCore-328 Physical Verification Suite")
    verifier.log("=" * 60)
    
    success = True
    
    if not args.skip_drc:
        success &= verifier.run_magic_drc()
        success &= verifier.run_klayout_drc()
        
    if not args.skip_lvs:
        success &= verifier.run_netgen_lvs()
        
    if not args.skip_pex:
        success &= verifier.run_parasitic_extraction()
        
    if not args.skip_timing:
        success &= verifier.run_timing_analysis()
        
    # Generate final report
    tape_out_ready = verifier.generate_verification_report()
    
    verifier.log("=" * 60)
    if tape_out_ready:
        verifier.log("🎉 VERIFICATION COMPLETE: READY FOR TAPE-OUT! 🎉")
        sys.exit(0)
    else:
        verifier.log("⚠️ VERIFICATION INCOMPLETE: FIX ISSUES BEFORE TAPE-OUT", "ERROR")
        sys.exit(1)

if __name__ == "__main__":
    main()